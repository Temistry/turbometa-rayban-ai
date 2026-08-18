import AVFoundation

@MainActor
final class GalvisAudioSessionController {
    func activateConversationSession() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(
            .playAndRecord,
            mode: .voiceChat,
            options: [.allowBluetooth, .allowBluetoothA2DP, .defaultToSpeaker]
        )
        try session.setActive(true, options: [.notifyOthersOnDeactivation])
        print("[Galvis][AUDIO] 음성 대화 세션 활성")
    }

    func deactivate() {
        do {
            try AVAudioSession.sharedInstance().setActive(
                false,
                options: [.notifyOthersOnDeactivation]
            )
            print("[Galvis][AUDIO] 음성 대화 세션 비활성")
        } catch {
            let nsError = error as NSError
            print("[Galvis][ERROR] 오디오 세션 종료 실패 domain=\(nsError.domain) code=\(nsError.code)")
        }
    }
}
