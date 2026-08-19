import XCTest

@testable import CameraAccess

final class OpenClawNotificationTests: XCTestCase {
    func testNotificationPreviewRemovesMarkdownURLAndCodeBlock() throws {
        let messageID = UUID()
        let content = try XCTUnwrap(
            OpenClawNotificationContent.make(
                text: """
                ## 완료
                [상세 설명](https://example.com)을 확인하세요.
                ```json
                {"secret":"not-for-notification"}
                ```
                """,
                messageID: messageID
            )
        )

        XCTAssertEqual(content.title, "openclaw.notification.title".localized)
        XCTAssertEqual(content.body, "완료 상세 설명을 확인하세요.")
        XCTAssertEqual(content.messageID, messageID)
        XCTAssertFalse(content.body.contains("https://"))
        XCTAssertFalse(content.body.contains("secret"))
    }

    func testNotificationPreviewUsesTheSharedSpeechSummary() throws {
        let text = [
            "첫 번째 핵심 문장입니다.",
            "두 번째 행동 문장입니다.",
            "세 번째 참고 문장입니다.",
            "네 번째 문장은 알림과 음성에서 제외해야 합니다."
        ].joined(separator: " ") + String(repeating: " 추가 설명", count: 50)

        let content = try XCTUnwrap(
            OpenClawNotificationContent.make(
                text: text,
                messageID: UUID()
            )
        )
        let speechSummary = try XCTUnwrap(
            GalvisSpeechResponseFormatter.speechText(from: text)
        )

        XCTAssertEqual(content.body, speechSummary)
        XCTAssertLessThanOrEqual(
            content.body.count,
            GalvisSpeechResponseFormatter.maximumSpeechLength
        )
        XCTAssertFalse(content.body.contains("네 번째"))
    }

    func testFinalSpeechPolicyDelegatesPendingConversationToGalvis() {
        XCTAssertTrue(
            OpenClawFinalSpeechPolicy.shouldAutoSpeak(
                hasPendingConversation: false
            )
        )
        XCTAssertFalse(
            OpenClawFinalSpeechPolicy.shouldAutoSpeak(
                hasPendingConversation: true
            )
        )
    }

    func testEmptyResponseDoesNotCreateNotificationContent() {
        XCTAssertNil(
            OpenClawNotificationContent.make(
                text: "```json\n{}\n```",
                messageID: UUID()
            )
        )
    }

    func testNotificationRouteAcceptsOnlyOpenClawCategoryAndUUID() {
        let messageID = UUID()
        let userInfo: [AnyHashable: Any] = [
            OpenClawNotificationContent.messageIDKey: messageID.uuidString
        ]

        XCTAssertEqual(
            OpenClawNotificationCoordinator.messageID(
                categoryIdentifier: OpenClawNotificationContent.categoryIdentifier,
                userInfo: userInfo
            ),
            messageID
        )
        XCTAssertNil(
            OpenClawNotificationCoordinator.messageID(
                categoryIdentifier: "OTHER",
                userInfo: userInfo
            )
        )
        XCTAssertNil(
            OpenClawNotificationCoordinator.messageID(
                categoryIdentifier: OpenClawNotificationContent.categoryIdentifier,
                userInfo: [OpenClawNotificationContent.messageIDKey: "invalid"]
            )
        )
    }
}
