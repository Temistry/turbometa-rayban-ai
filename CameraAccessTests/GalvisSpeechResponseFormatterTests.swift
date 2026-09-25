import XCTest
@testable import CameraAccess

final class GalvisSpeechResponseFormatterTests: XCTestCase {
    func testShortResponseRemainsUnchanged() {
        let text = "오후에 비가 올 수 있어요. 우산을 챙기세요."
        XCTAssertEqual(GalvisSpeechResponseFormatter.speechText(from: text), text)
    }

    func testLongResponseIsLimitedToThreeSentencesAndMaximumLength() {
        let text = [
            "첫 번째 핵심 문장입니다.",
            "두 번째 행동 문장입니다.",
            "세 번째 참고 문장입니다.",
            "네 번째 문장은 읽지 않아야 합니다."
        ].joined(separator: " ") + String(repeating: " 추가 설명", count: 50)

        let result = GalvisSpeechResponseFormatter.speechText(from: text)
        XCTAssertNotNil(result)
        XCTAssertLessThanOrEqual(result?.count ?? .max, 250)
        XCTAssertFalse(result?.contains("네 번째") ?? true)
    }

    func testMarkdownCodeAndURLAreNotSpoken() {
        let text = "# 결과\n핵심입니다. [문서](https://example.com)를 보세요. ```swift\nprint(1)\n```"
        let result = GalvisSpeechResponseFormatter.speechText(from: text)
        XCTAssertFalse(result?.contains("https://") ?? true)
        XCTAssertFalse(result?.contains("print(1)") ?? true)
        XCTAssertTrue(result?.contains("핵심입니다") ?? false)
    }
}
