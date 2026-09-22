import XCTest
@testable import CameraAccess

final class MeetingContextParsingTests: XCTestCase {
    func testParseExplanationPlainJSON() throws {
        let explanation = try XCTUnwrap(
            MeetingGeminiService.parseExplanation(
                "{\"term\":\"EBITDA\",\"text\":\"본업 수익성을 보는 지표예요."}"
            )
        )

        XCTAssertEqual(explanation.term, "EBITDA")
        XCTAssertEqual(explanation.text, "본업 수익성을 보는 지표예요.")
    }

    func testParseExplanationWithCodeFence() throws {
        let explanation = try XCTUnwrap(
            MeetingGeminiService.parseExplanation(
                "```json\n{\"term\":\"ROIC\",\"text\":\"투자 대비 수익성 지표입니다."}\n```"
            )
        )

        XCTAssertEqual(explanation.term, "ROIC")
        XCTAssertFalse(explanation.text.isEmpty)
    }

    func testParseExplanationRejectsInvalidAndEmpty() {
        XCTAssertNil(MeetingGeminiService.parseExplanation("설명 문장 그대로"))
        XCTAssertNil(MeetingGeminiService.parseExplanation("{\"term\":\"X\",\"text\":\"  \"}"))
    }

    func testParseSceneTermsAndSummary() throws {
        let context = try XCTUnwrap(
            VisualAssistService.parseScene(
                "{\"terms\":[\"EBITDA\",\" \",\"-\",\"없음\",\"Q3 실적\"],\"scene\":\"실적 슬라이드 발표 중\"}"
            )
        )

        XCTAssertEqual(context.terms, ["EBITDA", "Q3 실적"])
        XCTAssertEqual(context.scene, "실적 슬라이드 발표 중")
    }

    func testParseSceneWithCodeFenceAndCap() throws {
        let terms = (1...25).map { "용어\($0)" }
        let data = try JSONSerialization.data(withJSONObject: ["terms": terms, "scene": "회의"])
        let fenced = "```json\n\(String(data: data, encoding: .utf8) ?? "")\n```"

        let context = try XCTUnwrap(VisualAssistService.parseScene(fenced))

        XCTAssertEqual(context.terms.count, VisualAssistService.maxTerms)
        XCTAssertEqual(context.scene, "회의")
    }

    func testParseSceneReturnsNilForGarbage() {
        XCTAssertNil(VisualAssistService.parseScene("장면: 회의실"))
    }
}
