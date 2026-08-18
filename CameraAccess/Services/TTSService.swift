/*
 * 퀵비전 한국어 음성 출력 서비스
 *
 * AI 호출은 Google Gemini로 통일하고, 짧은 퀵비전 결과 낭독은 네트워크와 별도
 * 인증값이 필요 없는 iOS ko-KR 시스템 음성을 사용한다.
 */

import AVFoundation
import Foundation

enum TTSSpeechRate: String, CaseIterable, Identifiable {
    case slow
    case normal
    case fast

    var id: String { rawValue }

    var utteranceRate: Float {
        switch self {
        case .slow: return 0.42
        case .normal: return AVSpeechUtteranceDefaultSpeechRate
        case .fast: return 0.58
        }
    }
}

@MainActor
final class TTSService: NSObject, ObservableObject {
    static let shared = TTSService()

    @Published private(set) var isSpeaking = false
    @Published var speechRate: TTSSpeechRate = {
        TTSSpeechRate(
            rawValue: UserDefaults.standard.string(forKey: "tts_speech_rate") ?? ""
        ) ?? .normal
    }() {
        didSet {
            UserDefaults.standard.set(speechRate.rawValue, forKey: "tts_speech_rate")
        }
    }

    private var synthesizer: AVSpeechSynthesizer?
    private var speechContinuation: CheckedContinuation<Void, any Error>?
    private var activeSpeechID: UUID?

    private override init() {
        super.init()
    }

    func prepareAudioSession() {
        guard configurePlaybackAudioSession() else { return }
        print("[TTS][INFO] iOS 한국어 음성 재생 세션 준비 완료")
    }

    /// `apiKey`는 이전 호출부와의 소스 호환을 위해 남겨 두지만 사용하거나 기록하지 않는다.
    func speak(_ text: String, apiKey: String? = nil) {
        do {
            try beginSpeech(text, preservesAudioSession: false)
        } catch {
            let nsError = error as NSError
            print("[TTS][ERROR] 음성 재생 시작 실패 domain=\(nsError.domain) code=\(nsError.code)")
        }
    }

    func speakAndWait(
        _ text: String,
        preservesAudioSession: Bool = false
    ) async throws {
        stop()
        let speechID = try beginSpeech(text, preservesAudioSession: preservesAudioSession)
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard activeSpeechID == speechID else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                speechContinuation = continuation
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.stop() }
        }
    }

    @discardableResult
    private func beginSpeech(
        _ text: String,
        preservesAudioSession: Bool
    ) throws -> UUID {
        let normalizedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedText.isEmpty else {
            print("[TTS][WARN] 빈 문자열 음성 요청 무시")
            throw CocoaError(.validationMissingMandatoryProperty)
        }

        stop()
        guard preservesAudioSession || configurePlaybackAudioSession() else {
            print("[TTS][ERROR] 한국어 음성 재생 세션을 구성하지 못함")
            throw CocoaError(.fileWriteUnknown)
        }

        let voiceLanguage = LanguageManager.staticSystemVoiceLanguage
        guard let koreanVoice = AVSpeechSynthesisVoice(language: voiceLanguage)
            ?? AVSpeechSynthesisVoice.speechVoices().first(where: { $0.language.hasPrefix("ko") }) else {
            print("[TTS][ERROR] 설치된 한국어 시스템 음성을 찾지 못함")
            throw CocoaError(.featureUnsupported)
        }

        let speechID = UUID()
        let engine = AVSpeechSynthesizer()
        engine.delegate = self
        synthesizer = engine
        activeSpeechID = speechID

        let utterance = AVSpeechUtterance(string: normalizedText)
        utterance.voice = koreanVoice
        utterance.rate = speechRate.utteranceRate
        utterance.volume = 1.0
        utterance.pitchMultiplier = 1.0

        isSpeaking = true
        print(
            "[TTS][INFO] iOS 시스템 음성 요청 language=\(koreanVoice.language) "
            + "quality=\(koreanVoice.quality.rawValue) textLength=\(normalizedText.count) "
            + "rate=\(speechRate.rawValue) preservesSession=\(preservesAudioSession)"
        )
        engine.speak(utterance)
        return speechID
    }

    func stop() {
        let continuation = speechContinuation
        speechContinuation = nil
        activeSpeechID = nil

        guard let engine = synthesizer else {
            isSpeaking = false
            continuation?.resume(throwing: CancellationError())
            return
        }

        synthesizer = nil
        engine.delegate = nil
        engine.stopSpeaking(at: .immediate)
        isSpeaking = false
        continuation?.resume(throwing: CancellationError())
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
            return true
        } catch {
            let nsError = error as NSError
            print(
                "[TTS][ERROR] AudioSession 설정 실패 domain=\(nsError.domain) "
                + "code=\(nsError.code) description=\(nsError.localizedDescription)"
            )
            return false
        }
    }

    private func finishSpeech(
        from engine: AVSpeechSynthesizer,
        outcome: String,
        error: Error? = nil
    ) {
        guard synthesizer === engine else { return }
        engine.delegate = nil
        synthesizer = nil
        activeSpeechID = nil
        isSpeaking = false

        let continuation = speechContinuation
        speechContinuation = nil
        if let error {
            continuation?.resume(throwing: error)
        } else {
            continuation?.resume()
        }
        print("[TTS][INFO] iOS 한국어 음성 \(outcome)")
    }
}

extension TTSService: AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        didStart utterance: AVSpeechUtterance
    ) {
        Task { @MainActor [weak self, weak synthesizer] in
            guard let self, let synthesizer,
                  self.synthesizer === synthesizer else { return }
            self.isSpeaking = true
            print("[TTS][INFO] iOS 한국어 음성 재생 시작")
        }
    }

    nonisolated func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        didFinish utterance: AVSpeechUtterance
    ) {
        Task { @MainActor [weak self, weak synthesizer] in
            guard let self, let synthesizer else { return }
            self.finishSpeech(from: synthesizer, outcome: "재생 완료")
        }
    }

    nonisolated func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        didCancel utterance: AVSpeechUtterance
    ) {
        Task { @MainActor [weak self, weak synthesizer] in
            guard let self, let synthesizer else { return }
            self.finishSpeech(
                from: synthesizer,
                outcome: "재생 취소",
                error: CancellationError()
            )
        }
    }
}
