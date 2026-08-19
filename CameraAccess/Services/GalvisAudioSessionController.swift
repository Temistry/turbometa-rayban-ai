import AVFoundation

@MainActor
final class GalvisAudioSessionController {
    private(set) var isActive = false

    func activateConversationSession() throws {
        guard !isActive else {
            logCurrentRoute(event: "음성 대화 세션 이미 활성")
            return
        }

        let session = AVAudioSession.sharedInstance()
        try session.setCategory(
            .playAndRecord,
            mode: .voiceChat,
            options: [.allowBluetooth, .allowBluetoothA2DP, .defaultToSpeaker]
        )
        try session.setActive(true)
        isActive = true
        logCurrentRoute(event: "음성 대화 세션 활성")
    }

    func deactivate() {
        guard isActive else { return }

        do {
            try AVAudioSession.sharedInstance().setActive(
                false,
                options: [.notifyOthersOnDeactivation]
            )
            isActive = false
            print("[Galvis][AUDIO] 음성 대화 세션 비활성")
        } catch {
            let nsError = error as NSError
            print("[Galvis][ERROR] 오디오 세션 종료 실패 domain=\(nsError.domain) code=\(nsError.code)")
        }
    }

    private func logCurrentRoute(event: String) {
        let session = AVAudioSession.sharedInstance()
        let inputs = session.currentRoute.inputs
            .map { $0.portType.rawValue }
            .joined(separator: ",")
        let outputs = session.currentRoute.outputs
            .map { $0.portType.rawValue }
            .joined(separator: ",")
        print(
            "[Galvis][AUDIO] \(event) category=\(session.category.rawValue) "
            + "mode=\(session.mode.rawValue) inputs=[\(inputs)] outputs=[\(outputs)]"
        )
    }
}
