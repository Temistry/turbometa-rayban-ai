import Combine
import Foundation
import WatchConnectivity

final class PhoneLink: NSObject, ObservableObject {
    @Published var state = "idle"
    @Published var route = "-"
    @Published var startedAt: Date?
    @Published var latest = ""
    @Published var recent: [String] = []
    @Published var whisperCount = 0
    @Published var error = ""
    @Published var quotaPaused = false

    func activate() {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        guard session.activationState != .activated else { return }
        session.delegate = self
        session.activate()
    }

    func apply(_ context: [String: Any]) {
        if let value = context[WatchMeetingStatus.state] as? String { state = value }
        if let value = context[WatchMeetingStatus.route] as? String { route = value }
        if let value = context[WatchMeetingStatus.startedAt] as? TimeInterval {
            startedAt = Date(timeIntervalSince1970: value)
        }
        if let value = context[WatchMeetingStatus.latest] as? String { latest = value }
        if let value = context[WatchMeetingStatus.recent] as? [String] { recent = value }
        if let value = context[WatchMeetingStatus.whisperCount] as? Int { whisperCount = value }
        if let value = context[WatchMeetingStatus.error] as? String { error = value }
        if let value = context[WatchMeetingStatus.quotaPaused] as? Bool { quotaPaused = value }
    }
}

extension PhoneLink: WCSessionDelegate {
    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        let context = session.receivedApplicationContext
        DispatchQueue.main.async { [weak self] in
            self?.apply(context)
        }
    }

    func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        DispatchQueue.main.async { [weak self] in
            self?.apply(applicationContext)
        }
    }

#if os(iOS)
    // xcodebuild는 이 워치 타깃을 iOS SDK로도 컴파일한다(스킴 빌드 그래프 특성).
    // iOS SDK에서는 이 두 메서드가 필수이므로 iOS 컴파일에만 제공하고,
    // watchOS SDK에서는 unavailable이므로 생략한다.
    func sessionDidBecomeInactive(_ session: WCSession) {}

    func sessionDidDeactivate(_ session: WCSession) {
        session.activate()
    }
#endif
}
