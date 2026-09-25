import XCTest

@testable import CameraAccess

final class OpenClawSpeechResponseTests: XCTestCase {
    func testOnlyEnabledUniqueFinalResponseIsSpoken() {
        XCTAssertTrue(
            OpenClawSpeechResponseFormatter.shouldSpeak(
                state: "final",
                isEnabled: true,
                text: "완료되었습니다.",
                lastSpokenText: nil
            )
        )
        XCTAssertFalse(
            OpenClawSpeechResponseFormatter.shouldSpeak(
                state: "delta",
                isEnabled: true,
                text: "완료",
                lastSpokenText: nil
            )
        )
        XCTAssertFalse(
            OpenClawSpeechResponseFormatter.shouldSpeak(
                state: "final",
                isEnabled: false,
                text: "완료되었습니다.",
                lastSpokenText: nil
            )
        )
        XCTAssertFalse(
            OpenClawSpeechResponseFormatter.shouldSpeak(
                state: "final",
                isEnabled: true,
                text: "완료되었습니다.",
                lastSpokenText: "완료되었습니다."
            )
        )
    }

    func testPlainTextIsPreserved() {
        XCTAssertEqual(
            OpenClawSpeechResponseFormatter.textForSpeech("연결이 완료되었습니다."),
            "연결이 완료되었습니다."
        )
    }

    func testMarkdownLinksAndCodeAreSimplified() {
        let input = """
        ## 연결 결과
        - **Gateway**가 연결되었습니다.
        - [설명서](https://example.com)를 확인하세요.
        `openclaw devices list`
        ```json
        {"token":"not-for-speech"}
        ```
        """

        let output = OpenClawSpeechResponseFormatter.textForSpeech(input)

        XCTAssertEqual(
            output,
            "연결 결과 Gateway가 연결되었습니다. 설명서를 확인하세요. openclaw devices list"
        )
        XCTAssertFalse(output?.contains("https://") == true)
        XCTAssertFalse(output?.contains("token") == true)
    }

    func testEmptyMarkdownIsNotSpoken() {
        XCTAssertNil(OpenClawSpeechResponseFormatter.textForSpeech("```json\n{}\n```"))
        XCTAssertNil(OpenClawSpeechResponseFormatter.textForSpeech("   \n\t"))
    }

    func testLongResponseIsBoundedAtSentenceBoundary() {
        let sentence = String(repeating: "가", count: 700) + "."
        let input = sentence + " " + String(repeating: "나", count: 700)

        let output = OpenClawSpeechResponseFormatter.textForSpeech(input)

        XCTAssertEqual(output, sentence)
        XCTAssertLessThanOrEqual(output?.count ?? .max, OpenClawSpeechResponseFormatter.maximumLength)
    }

    func testLongResponseWithoutSentenceUsesEllipsis() {
        let input = String(repeating: "가", count: OpenClawSpeechResponseFormatter.maximumLength + 100)

        let output = OpenClawSpeechResponseFormatter.textForSpeech(input)

        XCTAssertEqual(output?.last, "…")
        XCTAssertEqual(output?.count, OpenClawSpeechResponseFormatter.maximumLength + 1)
    }
}
