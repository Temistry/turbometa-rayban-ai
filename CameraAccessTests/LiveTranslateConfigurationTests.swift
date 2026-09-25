/*
 * Live Translate Gemini configuration regression coverage.
 */

import XCTest

@testable import CameraAccess

final class LiveTranslateConfigurationTests: XCTestCase {
    func testTranslationInstructionUsesSelectedLanguagesAndOutputContract() {
        let instruction = LiveTranslateService.translationInstruction(
            sourceLanguage: .ko,
            targetLanguage: .ja
        )

        XCTAssertTrue(instruction.contains(TranslateLanguage.ko.displayName))
        XCTAssertTrue(instruction.contains(TranslateLanguage.ja.displayName))
        XCTAssertTrue(instruction.contains("번역 결과만"))
        XCTAssertTrue(instruction.contains("반드시 \(TranslateLanguage.ja.displayName)로 답하세요"))
    }
}
