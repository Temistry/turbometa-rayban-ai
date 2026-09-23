import Combine
import Foundation
import WatchConnectivity

@MainActor
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
    nonisolated func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: Error?
    ) {
        let context = session.receivedApplicationContext
        Task { @MainActor [weak self] in
            self?.apply(context)
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        Task { @MainActor [weak self] in
            self?.apply(applicationContext)
        }
    }

    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}

    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        session.activate()
    }
}
