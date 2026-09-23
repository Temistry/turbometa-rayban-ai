/*
 * 워치 동기화 다리 (폰 측)
 *
 * applicationContext 방식으로 최신 회의 상태를 워치에 밀어준다.
 * 전송 실패는 로그만 남기고 회의 기능에 절대 영향을 주지 않는다.
 */

import Foundation
import WatchConnectivity

@MainActor
final class WatchBridgeService: NSObject, ObservableObject {
    static let shared = WatchBridgeService()

    func activate() {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        guard session.activationState != .activated else { return }
        session.delegate = self
        session.activate()
    }

    func update(state: String, route: String, startedAt: Date?, latest: String,
                recent: [String], whisperCount: Int, error: String, quotaPaused: Bool) {
        guard WCSession.isSupported(), WCSession.default.activationState == .activated else { return }
        let payload = WatchMeetingStatus.payload(
            state: state,
            route: route,
            startedAt: startedAt,
            latest: latest,
            recent: recent,
            whisperCount: whisperCount,
            error: error,
            quotaPaused: quotaPaused
        )
        do {
            try WCSession.default.updateApplicationContext(payload)
        } catch {
            DeveloperConsole.shared.log(.warning, category: "MeetingWatch", "context update failed code=\((error as NSError).code)")
        }
    }
}

extension WatchBridgeService: WCSessionDelegate {
    nonisolated func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: Error?
    ) {
        // iOS 측 재활성화 흐름은 없다.
    }
}
