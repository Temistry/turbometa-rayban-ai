import Combine
import Foundation
import WatchConnectivity
import WatchKit

/// 워치 촬영 버튼을 누른 뒤 잠깐 보여 줄 결과.
enum CaptureFeedback: Equatable {
    case idle
    case sending
    case accepted
    case busy
    case unreachable
    case unavailable
    case failed
}

final class PhoneLink: NSObject, ObservableObject {
    @Published var state = "idle"
    @Published var route = "-"
    @Published var startedAt: Date?
    @Published var latest = ""
    @Published var recent: [String] = []
    @Published var whisperCount = 0
    @Published var error = ""
    @Published var quotaPaused = false
    @Published var scene = ""
    @Published var micQuiet = false
    /// 잡아낸 허점(최신이 앞). WatchMeetingStatus.catchEntry 형식.
    @Published var catches: [[String: String]] = []
    private var hasReceivedCatches = false
    @Published var captureFeedback: CaptureFeedback = .idle

    private var feedbackToken = UUID()

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
        if let value = context[WatchMeetingStatus.scene] as? String { scene = value }
        if let value = context[WatchMeetingStatus.micQuiet] as? Bool { micQuiet = value }
        if let value = context[WatchMeetingStatus.catches] as? [[String: String]] {
            let previousFirst = catches.first?[WatchMeetingStatus.catchID]
            let newFirst = value.first?[WatchMeetingStatus.catchID]
            // 화면을 보고 있을 때 새 항목이 오면 진동. 첫 수신(앱 열 때 복원)에는 울리지 않는다.
            if hasReceivedCatches, let newFirst, newFirst != previousFirst {
                WKInterfaceDevice.current().play(.notification)
            }
            hasReceivedCatches = true
            catches = value
        }
    }

    /// 폰에 촬영을 요청한다. 폰은 앱의 촬영 버튼과 같은 동작(촬영→설명→귓속말)을 한다.
    func requestCapture() {
        guard captureFeedback != .sending else { return }
        let session = WCSession.default
        guard session.activationState == .activated, session.isReachable else {
            show(.unreachable)
            return
        }
        captureFeedback = .sending
        WKInterfaceDevice.current().play(.click)
        session.sendMessage(
            [WatchCapture.actionKey: WatchCapture.captureAction],
            replyHandler: { [weak self] reply in
                let result = reply[WatchCapture.resultKey] as? String
                DispatchQueue.main.async {
                    switch result {
                    case WatchCapture.accepted: self?.show(.accepted)
                    case WatchCapture.busy: self?.show(.busy)
                    default: self?.show(.unavailable)
                    }
                }
            },
            errorHandler: { [weak self] _ in
                DispatchQueue.main.async { self?.show(.failed) }
            }
        )
    }

    private func show(_ feedback: CaptureFeedback) {
        captureFeedback = feedback
        WKInterfaceDevice.current().play(feedback == .accepted ? .success : .failure)
        let token = UUID()
        feedbackToken = token
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self, self.feedbackToken == token else { return }
            self.captureFeedback = .idle
        }
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
}
