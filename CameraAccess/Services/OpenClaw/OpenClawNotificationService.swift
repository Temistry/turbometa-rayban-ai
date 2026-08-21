import Foundation
import UserNotifications

struct OpenClawNotificationContent: Equatable {
    static let categoryIdentifier = "OPENCLAW_FINAL_RESPONSE"
    static let messageIDKey = "openClawMessageID"

    let title: String
    let body: String
    let messageID: UUID

    static func make(text: String, messageID: UUID) -> OpenClawNotificationContent? {
        guard let summary = GalvisSpeechResponseFormatter.speechText(from: text) else {
            return nil
        }
        return make(summary: summary, messageID: messageID)
    }

    static func make(summary: String, messageID: UUID) -> OpenClawNotificationContent? {
        let normalized = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return nil }

        return OpenClawNotificationContent(
            title: "openclaw.notification.title".localized,
            body: normalized,
            messageID: messageID
        )
    }
}

final class OpenClawNotificationService {
    static let shared = OpenClawNotificationService()

    private let center: UNUserNotificationCenter

    init(center: UNUserNotificationCenter = .current()) {
        self.center = center
    }

    func requestAuthorizationIfNeeded() {
        center.getNotificationSettings { [weak self] settings in
            guard settings.authorizationStatus == .notDetermined else { return }
            self?.requestAuthorization(completion: nil)
        }
    }

    func postFinalResponse(text: String, messageID: UUID) {
        guard let content = OpenClawNotificationContent.make(
            text: text,
            messageID: messageID
        ) else {
            print("[OpenClawNotification][WARN] 알림 미리보기를 만들 수 없음")
            return
        }
        postFinalResponse(content)
    }

    func postFinalResponse(summary: String, messageID: UUID) {
        guard let content = OpenClawNotificationContent.make(
            summary: summary,
            messageID: messageID
        ) else {
            print("[OpenClawNotification][WARN] 알림 미리보기를 만들 수 없음")
            return
        }
        postFinalResponse(content)
    }

    private func postFinalResponse(_ content: OpenClawNotificationContent) {
        center.getNotificationSettings { [weak self] settings in
            guard let self else { return }
            switch settings.authorizationStatus {
            case .authorized, .provisional, .ephemeral:
                self.add(content)
            case .notDetermined:
                self.requestAuthorization { granted in
                    guard granted else { return }
                    self.add(content)
                }
            case .denied:
                print("[OpenClawNotification][INFO] 알림 권한이 거부되어 표시하지 않음")
            @unknown default:
                print("[OpenClawNotification][WARN] 알 수 없는 알림 권한 상태")
            }
        }
    }

    private func requestAuthorization(completion: ((Bool) -> Void)?) {
        center.requestAuthorization(options: [.alert, .sound]) { granted, error in
            if let error {
                let nsError = error as NSError
                print(
                    "[OpenClawNotification][ERROR] 권한 요청 실패 "
                    + "domain=\(nsError.domain) code=\(nsError.code)"
                )
            } else {
                print("[OpenClawNotification][INFO] 알림 권한 요청 완료 granted=\(granted)")
            }
            completion?(granted)
        }
    }

    private func add(_ notification: OpenClawNotificationContent) {
        let content = UNMutableNotificationContent()
        content.title = notification.title
        content.body = notification.body
        content.sound = .default
        content.categoryIdentifier = OpenClawNotificationContent.categoryIdentifier
        content.userInfo = [
            OpenClawNotificationContent.messageIDKey: notification.messageID.uuidString
        ]

        let request = UNNotificationRequest(
            identifier: "openclaw-final-\(notification.messageID.uuidString)",
            content: content,
            trigger: nil
        )
        center.add(request) { error in
            if let error {
                let nsError = error as NSError
                print(
                    "[OpenClawNotification][ERROR] 알림 등록 실패 "
                    + "domain=\(nsError.domain) code=\(nsError.code)"
                )
            } else {
                print(
                    "[OpenClawNotification][INFO] 최종 답변 알림 등록 완료 "
                    + "previewLength=\(notification.body.count)"
                )
            }
        }
    }
}
