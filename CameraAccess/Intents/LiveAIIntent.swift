/*
 * Live AI Intent
 * Siri와 단축어에서 Live AI를 실행한다.
 */

import AppIntents
import UIKit

@available(iOS 16.0, *)
struct LiveAIIntent: AppIntent {
    static var title: LocalizedStringResource = "실시간 대화"
    static var description = IntentDescription("실시간 멀티모달 AI 대화를 시작합니다")
    static var openAppWhenRun: Bool = true

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        NotificationCenter.default.post(name: .liveAITriggered, object: nil)
        return .result(dialog: "실시간 대화를 시작합니다")
    }
}

@available(iOS 16.0, *)
struct StopLiveAIIntent: AppIntent {
    static var title: LocalizedStringResource = "실시간 대화 중지"
    static var description = IntentDescription("실행 중인 실시간 AI 대화를 중지합니다")
    static var openAppWhenRun: Bool = false

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let manager = LiveAIManager.shared

        if manager.isRunning {
            await manager.stopSession()
            return .result(dialog: "실시간 AI 대화를 중지했습니다")
        } else {
            return .result(dialog: "실시간 AI가 실행 중이 아닙니다")
        }
    }
}

extension Notification.Name {
    static let liveAITriggered = Notification.Name("liveAITriggered")
}
