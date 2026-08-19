import AVFoundation
import Foundation

@MainActor
final class OpenClawAudioPlaybackService: NSObject, ObservableObject {
    static let shared = OpenClawAudioPlaybackService()

    @Published private(set) var isPlaying = false

    private var player: AVAudioPlayer?
    private var playbackContinuation: CheckedContinuation<Void, any Error>?
    private var activePlaybackID: UUID?

    private override init() {
        super.init()
    }

    func playAndWait(_ audio: OpenClawSpeechAudio) async throws {
        stop()
        try configureAudioSession()

        let playbackID = UUID()
        let engine: AVAudioPlayer
        do {
            engine = try AVAudioPlayer(data: audio.data)
        } catch {
            throw OpenClawSpeechError.playbackFailed
        }

        player = engine
        activePlaybackID = playbackID
        engine.delegate = self
        engine.prepareToPlay()
        isPlaying = true

        print(
            "[OpenClaw][SPEECH] Gateway 음성 재생 준비 "
            + "provider=\(audio.provider) bytes=\(audio.data.count)"
        )

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, any Error>) in
                guard activePlaybackID == playbackID else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                playbackContinuation = continuation
                guard engine.play() else {
                    finishPlayback(
                        from: engine,
                        result: .failure(OpenClawSpeechError.playbackFailed)
                    )
                    return
                }
                print("[OpenClaw][SPEECH] Gateway 음성 재생 시작")
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.stop() }
        }
    }

    func stop() {
        let continuation = playbackContinuation
        playbackContinuation = nil
        activePlaybackID = nil

        if let engine = player {
            engine.delegate = nil
            engine.stop()
        }
        player = nil
        isPlaying = false
        continuation?.resume(throwing: CancellationError())
    }

    private func configureAudioSession() throws {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(
                .playAndRecord,
                mode: .voiceChat,
                options: [.allowBluetooth, .allowBluetoothA2DP, .defaultToSpeaker]
            )
            try session.setActive(true, options: [.notifyOthersOnDeactivation])
        } catch {
            let nsError = error as NSError
            print(
                "[OpenClaw][ERROR] Gateway 음성 AudioSession 설정 실패 "
                + "domain=\(nsError.domain) code=\(nsError.code)"
            )
            throw OpenClawSpeechError.playbackFailed
        }
    }

    private func finishPlayback(
        from engine: AVAudioPlayer,
        result: Result<Void, Error>
    ) {
        guard player === engine else { return }
        engine.delegate = nil
        player = nil
        activePlaybackID = nil
        isPlaying = false

        let continuation = playbackContinuation
        playbackContinuation = nil
        continuation?.resume(with: result)
    }
}

extension OpenClawAudioPlaybackService: AVAudioPlayerDelegate {
    nonisolated func audioPlayerDidFinishPlaying(
        _ player: AVAudioPlayer,
        successfully flag: Bool
    ) {
        Task { @MainActor [weak self, weak player] in
            guard let self, let player else { return }
            let result: Result<Void, Error> = flag
                ? .success(())
                : .failure(OpenClawSpeechError.playbackFailed)
            self.finishPlayback(from: player, result: result)
            print("[OpenClaw][SPEECH] Gateway 음성 재생 완료 success=\(flag)")
        }
    }

    nonisolated func audioPlayerDecodeErrorDidOccur(
        _ player: AVAudioPlayer,
        error: Error?
    ) {
        Task { @MainActor [weak self, weak player] in
            guard let self, let player else { return }
            self.finishPlayback(
                from: player,
                result: .failure(OpenClawSpeechError.playbackFailed)
            )
            let nsError = error as NSError?
            print(
                "[OpenClaw][ERROR] Gateway 음성 디코딩 실패 "
                + "domain=\(nsError?.domain ?? "-") code=\(nsError?.code ?? 0)"
            )
        }
    }
}
