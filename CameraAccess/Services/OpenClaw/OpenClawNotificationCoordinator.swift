import Foundation
import UserNotifications

final class OpenClawNotificationCoordinator: NSObject, UNUserNotificationCenterDelegate {
    static let shared = OpenClawNotificationCoordinator()

    private override init() {
        super.init()
    }

    func install() {
        UNUserNotificationCenter.current().delegate = self
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        guard notification.request.content.categoryIdentifier
                == OpenClawNotificationContent.categoryIdentifier else {
            completionHandler([])
            return
        }
        completionHandler([.banner, .sound])
    }

    static func messageID(
        categoryIdentifier: String,
        userInfo: [AnyHashable: Any]
    ) -> UUID? {
        guard categoryIdentifier == OpenClawNotificationContent.categoryIdentifier,
              let rawMessageID = userInfo[
                OpenClawNotificationContent.messageIDKey
              ] as? String else {
            return nil
        }
        return UUID(uuidString: rawMessageID)
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        defer { completionHandler() }

        let content = response.notification.request.content
        guard let messageID = Self.messageID(
            categoryIdentifier: content.categoryIdentifier,
            userInfo: content.userInfo
        ) else {
            return
        }

        Task { @MainActor in
            GalvisLaunchCoordinator.shared.requestOpenClawChat(messageID: messageID)
        }
    }
}
