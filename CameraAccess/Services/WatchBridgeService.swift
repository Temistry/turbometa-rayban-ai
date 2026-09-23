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

    /// 워치 앱이 아직 없을 때 보관했다가 설치 즉시 보낼 최신 상태.
    private var pendingPayload: [String: Any]?
    /// 같은 경고가 갱신마다 반복되지 않도록 마지막으로 기록한 워치 상태.
    private var lastLoggedReachability: String?

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
        send(payload)
    }

    /// 페어링된 워치에 앱이 설치되어 있을 때만 보낸다(미설치 시 WCError 7006).
    private func send(_ payload: [String: Any]) {
        let session = WCSession.default
        let reachability = !session.isPaired ? "notPaired"
            : (!session.isWatchAppInstalled ? "appNotInstalled" : "ready")
        if reachability != lastLoggedReachability {
            lastLoggedReachability = reachability
            DeveloperConsole.shared.log(.info, category: "MeetingWatch", "watch state=\(reachability)")
        }
        guard reachability == "ready" else {
            pendingPayload = payload
            return
        }
        pendingPayload = nil
        do {
            try session.updateApplicationContext(payload)
        } catch {
            DeveloperConsole.shared.log(.warning, category: "MeetingWatch", "context update failed code=\((error as NSError).code)")
        }
    }

    fileprivate func flushPendingIfReady() {
        guard let payload = pendingPayload else { return }
        send(payload)
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

    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}

    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        session.activate()
    }

    /// 워치에 앱이 새로 설치되거나 페어링이 바뀌면 보관한 최신 상태를 보낸다.
    nonisolated func sessionWatchStateDidChange(_ session: WCSession) {
        Task { @MainActor in
            WatchBridgeService.shared.flushPendingIfReady()
        }
    }
}
