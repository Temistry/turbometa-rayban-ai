/*
 * 퀵비전 한국어 음성 출력 서비스
 *
 * AI 호출은 Google Gemini로 통일하고, 짧은 퀵비전 결과 낭독은 네트워크와 별도
 * 인증값이 필요 없는 iOS ko-KR 시스템 음성을 사용한다.
 */

import AVFoundation
import Foundation

@MainActor
final class TTSService: NSObject, ObservableObject {
    static let shared = TTSService()

    @Published private(set) var isSpeaking = false

    private var synthesizer: AVSpeechSynthesizer?
    private var playbackTask: Task<Void, Never>?

    private override init() {
        super.init()
    }

    func prepareAudioSession() {
        guard configurePlaybackAudioSession() else { return }
        print("[TTS][INFO] iOS 한국어 음성 재생 세션 준비 완료")
    }

    /// `apiKey`는 이전 호출부와의 소스 호환을 위해 남겨 두지만 사용하거나 기록하지 않는다.
    func speak(_ text: String, apiKey: String? = nil) {
        let normalizedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedText.isEmpty else {
            print("[TTS][WARN] 빈 문자열 음성 요청 무시")
            return
        }

        stop()
        guard configurePlaybackAudioSession() else {
            print("[TTS][ERROR] 한국어 음성 재생 세션을 구성하지 못함")
            return
        }

        let voiceLanguage = LanguageManager.staticSystemVoiceLanguage
        guard let koreanVoice = AVSpeechSynthesisVoice(language: voiceLanguage)
            ?? AVSpeechSynthesisVoice.speechVoices().first(where: { $0.language.hasPrefix("ko") }) else {
            print("[TTS][ERROR] 설치된 한국어 시스템 음성을 찾지 못함")
            return
        }

        let engine = AVSpeechSynthesizer()
        synthesizer = engine

        let utterance = AVSpeechUtterance(string: normalizedText)
        utterance.voice = koreanVoice
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        utterance.volume = 1.0
        utterance.pitchMultiplier = 1.0

        isSpeaking = true
        print(
            "[TTS][INFO] iOS 시스템 음성 시작 language=\(koreanVoice.language) "
            + "quality=\(koreanVoice.quality.rawValue) textLength=\(normalizedText.count)"
        )
        engine.speak(utterance)

        playbackTask = Task { [weak self, weak engine] in
            guard let self, let engine else { return }

            while engine.isSpeaking {
                if Task.isCancelled {
                    engine.stopSpeaking(at: .immediate)
                    return
                }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }

            guard !Task.isCancelled else { return }
            self.isSpeaking = false
            self.synthesizer = nil
            self.playbackTask = nil
            print("[TTS][INFO] iOS 한국어 음성 재생 완료")
        }
    }

    func stop() {
        playbackTask?.cancel()
        playbackTask = nil
        synthesizer?.stopSpeaking(at: .immediate)
        synthesizer = nil
        isSpeaking = false
        print("[TTS][INFO] 음성 재생 중지")
    }

    @discardableResult
    private func configurePlaybackAudioSession() -> Bool {
        let session = AVAudioSession.sharedInstance()

        do {
            try session.setCategory(
                .playback,
                mode: .spokenAudio,
                options: [.duckOthers, .allowBluetoothA2DP]
            )
            try session.setActive(true, options: [.notifyOthersOnDeactivation])

            let outputs = session.currentRoute.outputs
                .map { "\($0.portType.rawValue):\($0.portName)" }
                .joined(separator: ",")
            print(
                "[TTS][AUDIO] 세션 활성 category=\(session.category.rawValue) "
                + "mode=\(session.mode.rawValue) outputs=[\(outputs)]"
            )
            return !session.currentRoute.outputs.isEmpty
        } catch {
            let nsError = error as NSError
            print(
                "[TTS][ERROR] AudioSession 설정 실패 domain=\(nsError.domain) "
                + "code=\(nsError.code) description=\(nsError.localizedDescription)"
            )
            return false
        }
    }
}
