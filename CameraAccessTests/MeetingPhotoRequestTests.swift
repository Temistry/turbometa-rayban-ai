import XCTest
@testable import CameraAccess

final class MeetingPhotoRequestTests: XCTestCase {
    func testSilentPhotoRequestPreservesOriginalBytes() throws {
        let original = Data([0xff, 0xd8, 0x00, 0x12, 0x34, 0xff, 0xd9])
        let body = MeetingGeminiService.photoRequestBody(jpegData: original, recentContext: "")
        let encoded = try JSONSerialization.data(withJSONObject: body)
        let decoded = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        let contents = try XCTUnwrap(decoded["contents"] as? [[String: Any]])
        let parts = try XCTUnwrap(contents.first?["parts"] as? [[String: Any]])
        let attachment = try XCTUnwrap(parts.last?["inline_data"] as? [String: String])
        XCTAssertEqual(attachment["mime_type"], "image/jpeg")
        XCTAssertEqual(Data(base64Encoded: try XCTUnwrap(attachment["data"])), original)
        XCTAssertFalse(try XCTUnwrap(parts.first?["text"] as? String).isEmpty)
    }

    func testBlockedOrEmptyPhotoResponseDoesNotBecomeSpeech() {
        XCTAssertNil(MeetingGeminiService.parseText(["promptFeedback": ["blockReason": "SAFETY"]]))
        XCTAssertNil(MeetingGeminiService.parseText([
            "candidates": [["content": ["parts": [["text": "  \n"]]]]]
        ]))
    }

    /// 빌드 75: 생각 토큰이 256 한도를 다 써서 finish=MAX_TOKENS로 귓속말 JSON이 잘렸다.
    func testWhisperRequestLimitsThinkingAndLeavesOutputRoom() throws {
        let body = MeetingGeminiService.explainRequestBody(
            utterance: "이번 분기 EBITDA가 개선됐습니다",
            recentContext: "",
            sceneContext: nil,
            explainedTerms: []
        )
        let config = try XCTUnwrap(body["generationConfig"] as? [String: Any])
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(config["maxOutputTokens"] as? Int), 1024)
        XCTAssertEqual(config["responseMimeType"] as? String, "application/json")
        let thinking = try XCTUnwrap(config["thinkingConfig"] as? [String: Any])
        XCTAssertEqual(thinking["thinkingLevel"] as? String, "low")
        XCTAssertNoThrow(try JSONSerialization.data(withJSONObject: body))
    }

    func testPhotoRequestAlsoLimitsThinking() throws {
        let body = MeetingGeminiService.photoRequestBody(jpegData: Data([0xff, 0xd8]), recentContext: "")
        XCTAssertTrue(MeetingGeminiService.hasThinkingConfig(body))
        let config = try XCTUnwrap(body["generationConfig"] as? [String: Any])
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(config["maxOutputTokens"] as? Int), 1024)
    }

    func testRemovingThinkingConfigKeepsOtherSettings() throws {
        let body = MeetingGeminiService.explainRequestBody(
            utterance: "API 연동", recentContext: "", sceneContext: nil, explainedTerms: []
        )
        let stripped = MeetingGeminiService.removingThinkingConfig(body)
        XCTAssertFalse(MeetingGeminiService.hasThinkingConfig(stripped))
        let config = try XCTUnwrap(stripped["generationConfig"] as? [String: Any])
        XCTAssertEqual(config["responseMimeType"] as? String, "application/json")
        XCTAssertEqual(config["maxOutputTokens"] as? Int, 1024)
        XCTAssertNotNil(stripped["contents"])
    }

    /// 빌드 79: 429가 났지만 분당·일일 한도 중 무엇인지 로그로 구분할 수 없었다.
    func testQuotaDiagnosticNamesLimitAndRetryDelay() throws {
        let body: [String: Any] = [
            "error": [
                "code": 429,
                "status": "RESOURCE_EXHAUSTED",
                "message": "You exceeded your current quota",
                "details": [
                    [
                        "@type": "type.googleapis.com/google.rpc.QuotaFailure",
                        "violations": [[
                            "quotaMetric": "generativelanguage.googleapis.com/generate_content_free_tier_requests",
                            "quotaId": "GenerateRequestsPerDayPerProjectPerModel-FreeTier",
                            "quotaValue": "250"
                        ]]
                    ],
                    ["@type": "type.googleapis.com/google.rpc.RetryInfo", "retryDelay": "41s"]
                ]
            ]
        ]
        let data = try JSONSerialization.data(withJSONObject: body)
        let line = MeetingGeminiService.quotaDiagnostic(from: data)
        XCTAssertTrue(line.contains("GenerateRequestsPerDayPerProjectPerModel-FreeTier(250)"))
        XCTAssertTrue(line.contains("retryDelay=41s"))
        XCTAssertFalse(line.contains("exceeded"))
        XCTAssertEqual(MeetingGeminiService.quotaDiagnostic(from: Data("not json".utf8)), "quotaId=- retryDelay=-")
    }

    func testUsageParsingCountsThoughtsAsOutput() throws {
        let usage = try XCTUnwrap(GeminiUsage.from([
            "usageMetadata": [
                "promptTokenCount": 800,
                "candidatesTokenCount": 60,
                "thoughtsTokenCount": 140,
                "totalTokenCount": 1000
            ]
        ]))
        XCTAssertEqual(usage.input, 800)
        XCTAssertEqual(usage.output, 200)
        XCTAssertNil(GeminiUsage.from(["candidates": []]))
    }

    func testCostEstimateUsesFlashPrices() {
        // 입력 100만 토큰 0.75달러 + 출력 100만 토큰 3.75달러
        let usage = GeminiUsage(prompt: 1_000_000, toolPrompt: 0, candidates: 500_000, thoughts: 500_000)
        XCTAssertEqual(GeminiUsageLedger.estimatedCost(usage), 4.5, accuracy: 0.0001)
    }

    func testLedgerSummarizesByLane() {
        let ledger = GeminiUsageLedger()
        ledger.record(lane: "scene", usage: GeminiUsage(prompt: 700, toolPrompt: 0, candidates: 50, thoughts: 100))
        ledger.record(lane: "scene", usage: GeminiUsage(prompt: 700, toolPrompt: 0, candidates: 50, thoughts: 100))
        ledger.record(lane: "whisper", usage: GeminiUsage(prompt: 500, toolPrompt: 0, candidates: 40, thoughts: 60))
        let summary = ledger.summary()
        XCTAssertTrue(summary.contains("requests=3"))
        XCTAssertTrue(summary.contains("in=1900"))
        XCTAssertTrue(summary.contains("out=400(thoughts=260)"))
        XCTAssertTrue(summary.contains("lanes=scene:2,whisper:1"))
        ledger.reset()
        XCTAssertTrue(ledger.summary().contains("requests=0"))
    }

    /// 자동 장면 사진만 중간 해상도를 붙이고, 형식은 Gemini 3 사진별 해상도 규격을 따른다.
    func testSceneImageRequestCarriesMediaResolution() throws {
        let data = try QuickVisionService.encodedRequestBody(
            prompt: "장면", imageBase64: "AAAA", thinking: true,
            mediaResolution: VisualAssistService.sceneMediaResolution
        )
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let contents = try XCTUnwrap(object["contents"] as? [[String: Any]])
        let parts = try XCTUnwrap(contents.first?["parts"] as? [[String: Any]])
        let image = try XCTUnwrap(parts.last)
        let resolution = try XCTUnwrap(image["mediaResolution"] as? [String: Any])
        XCTAssertEqual(resolution["level"] as? String, "MEDIA_RESOLUTION_MEDIUM")
        XCTAssertNil(parts.first?["mediaResolution"])

        let plain = try QuickVisionService.encodedRequestBody(
            prompt: "장면", imageBase64: "AAAA", thinking: false, mediaResolution: nil
        )
        let plainText = String(decoding: plain, as: UTF8.self)
        XCTAssertFalse(plainText.contains("mediaResolution"))
        XCTAssertFalse(plainText.contains("thinkingConfig"))
    }
}
