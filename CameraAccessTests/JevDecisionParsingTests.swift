import XCTest
@testable import CameraAccess

final class JevDecisionParsingTests: XCTestCase {
    func testParseAnswersFromDocumentedChoiceResponse() throws {
        let json = """
        {"model":"jev-1.13.0","answers":{"department":{"type":"choice","choice":"technical","probabilities":{"billing":0.08,"technical":0.85,"sales":0.07},"confidence":0.82},"needs_explanation":{"type":"choice","choice":"yes","probabilities":{"yes":0.91,"no":0.09}}},"usage":{"input_tokens":312,"output_tokens":48}}
        """.data(using: .utf8)!

        let answers = try JevClient.parseAnswers(json)

        XCTAssertEqual(answers["department"]?.value, "technical")
        XCTAssertEqual(answers["department"]?.confidence ?? 0, 0.82, accuracy: 0.0001)
        XCTAssertEqual(answers["needs_explanation"]?.value, "yes")
        XCTAssertEqual(answers["needs_explanation"]?.confidence ?? 0, 0.91, accuracy: 0.0001)
    }

    func testParseAnswersThrowsWhenAnswersMissing() {
        XCTAssertThrowsError(try JevClient.parseAnswers(Data("{}".utf8)))
    }

    func testMissingConfidenceFailsInsteadOfSilentlyDisablingWhispers() {
        XCTAssertThrowsError(try JevClient.parseAnswers(Data(
            "{\"answers\":{\"needs_explanation\":{\"choice\":\"yes\"}}}".utf8)))
    }

    func testZeroConfidenceIsNotReplacedByProbability() throws {
        let result = try JevClient.parseAnswers(Data(
            "{\"answers\":{\"needs_explanation\":{\"choice\":\"yes\",\"confidence\":0,\"probabilities\":{\"yes\":0.9}}}}".utf8))
        XCTAssertEqual(result["needs_explanation"]?.confidence, 0)
    }

    func testDecisionMapsLanesAndConfidence() {
        let answers = [
            "needs_explanation": JevAnswer(value: "yes", confidence: 0.93),
            "lane": JevAnswer(value: "factcheck", confidence: 0.7)
        ]

        let decision = JevUtteranceDecision.make(answers: answers)

        XCTAssertTrue(decision.needsExplanation)
        XCTAssertEqual(decision.lane, .factcheck)
        XCTAssertEqual(decision.explanationConfidence, 0.93, accuracy: 0.0001)
    }

    func testDecisionDefaultsToNoLane() {
        let decision = JevUtteranceDecision.make(answers: [:])

        XCTAssertFalse(decision.needsExplanation)
        XCTAssertEqual(decision.lane, .none)
        XCTAssertEqual(decision.explanationConfidence, 0, accuracy: 0.0001)
    }

    func testDecisionCarriesTermCategory() {
        let answers = [
            "needs_explanation": JevAnswer(value: "yes", confidence: 0.9),
            "category": JevAnswer(value: "dev", confidence: 0.95),
            "lane": JevAnswer(value: "explain", confidence: 0.9)
        ]

        XCTAssertEqual(JevUtteranceDecision.make(answers: answers).category, "dev")
        XCTAssertEqual(JevUtteranceDecision.make(answers: [:]).category, "none")
    }

    func testGeminiGroundingLinkParsing() {
        let object: [String: Any] = [
            "candidates": [
                [
                    "content": ["parts": [["text": "지지 근거 2건"]]],
                    "groundingMetadata": [
                        "groundingChunks": [
                            ["web": ["uri": "https://example.com/a", "title": " 보고서 "]],
                            ["web": ["uri": "https://example.com/a", "title": "중복"]],
                            ["web": ["uri": "https://example.com/b"]],
                            ["web": ["uri": "https://example.com/c", "title": "세 번째"]]
                        ]
                    ]
                ]
            ]
        ]

        XCTAssertEqual(MeetingGeminiService.parseText(object), "지지 근거 2건")

        let links = MeetingGeminiService.parseGroundingLinks(object)
        XCTAssertEqual(links.count, 3)
        XCTAssertEqual(links[0].title, "보고서")
        XCTAssertEqual(links[1].title, "https://example.com/b")
        XCTAssertEqual(links[2].urlString, "https://example.com/c")
    }
}
