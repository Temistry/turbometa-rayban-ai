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

    func testNotificationPreviewIsBounded() throws {
        let content = try XCTUnwrap(
            OpenClawNotificationContent.make(
                text: String(
                    repeating: "가",
                    count: OpenClawNotificationContent.maximumPreviewLength + 100
                ),
                messageID: UUID()
            )
        )

        XCTAssertEqual(
            content.body.count,
            OpenClawNotificationContent.maximumPreviewLength + 1
        )
        XCTAssertEqual(content.body.last, "…")
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
