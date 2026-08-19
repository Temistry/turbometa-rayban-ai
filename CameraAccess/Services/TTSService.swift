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
    enum PlaybackState: Equatable {
        case idle
        case queued(UUID)
        case speaking(UUID)
        case failed(UUID)

        var requestID: UUID? {
            switch self {
            case .idle:
                return nil
            case let .queued(requestID),
                 let .speaking(requestID),
                 let .failed(requestID):
                return requestID
            }
        }

        func isActive(requestID: UUID) -> Bool {
            switch self {
            case let .queued(activeRequestID), let .speaking(activeRequestID):
                return activeRequestID == requestID
            case .idle, .failed:
                return false
            }
        }
    }

    static let shared = TTSService()

    @Published private(set) var playbackState: PlaybackState = .idle

    var isSpeaking: Bool {
        switch playbackState {
        case .queued, .speaking:
            return true
        case .idle, .failed:
            return false
        }
    }

    private let synthesizer = AVSpeechSynthesizer()
    private var currentUtterance: AVSpeechUtterance?
    private var currentRequestID: UUID?

    private override init() {
        super.init()
        synthesizer.delegate = self
    }

    func prepareAudioSession() {
        guard configurePlaybackAudioSession() else { return }
        print("[TTS][INFO] iOS 한국어 음성 재생 세션 준비 완료")
    }

    /// `apiKey`는 이전 호출부와의 소스 호환을 위해 남겨 두지만 사용하거나 기록하지 않는다.
    @discardableResult
    func speak(_ text: String, apiKey: String? = nil) -> Bool {
        enqueue(text) != nil
    }

    /// 발화 요청을 queue에 넣고 UI와 세션 handoff에서 추적할 request ID를 반환한다.
    @discardableResult
    func enqueue(_ text: String) -> UUID? {
        let normalizedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedText.isEmpty else {
            print("[TTS][WARN] 빈 문자열 음성 요청 무시")
            return nil
        }

        stop()
        guard configurePlaybackAudioSession() else {
            print("[TTS][ERROR] 한국어 음성 재생 세션을 구성하지 못함")
            return nil
        }

        let voiceLanguage = LanguageManager.staticSystemVoiceLanguage
        guard let koreanVoice = AVSpeechSynthesisVoice(language: voiceLanguage)
            ?? AVSpeechSynthesisVoice.speechVoices().first(where: { $0.language.hasPrefix("ko") }) else {
            print("[TTS][ERROR] 설치된 한국어 시스템 음성을 찾지 못함")
            return nil
        }

        let requestID = UUID()
        let utterance = AVSpeechUtterance(string: normalizedText)
        utterance.voice = koreanVoice
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        utterance.volume = 1.0
        utterance.pitchMultiplier = 1.0

        currentRequestID = requestID
        currentUtterance = utterance
        playbackState = .queued(requestID)
        scheduleStartTimeout(requestID: requestID)
        print(
            "[TTS][QUEUE] 요청 접수 request=\(logID(requestID)) "
            + "language=\(koreanVoice.language) quality=\(koreanVoice.quality.rawValue) "
            + "textLength=\(normalizedText.count)"
        )
        synthesizer.speak(utterance)
        return requestID
    }

    func stop() {
        guard currentRequestID != nil || synthesizer.isSpeaking || synthesizer.isPaused else {
            playbackState = .idle
            return
        }

        let requestID = currentRequestID
        currentRequestID = nil
        currentUtterance = nil
        playbackState = .idle
        synthesizer.stopSpeaking(at: .immediate)
        if let requestID {
            print("[TTS][INFO] 음성 재생 중지 request=\(logID(requestID))")
        }
    }

    func isActive(requestID: UUID) -> Bool {
        playbackState.isActive(requestID: requestID)
    }

    private func scheduleStartTimeout(requestID: UUID) {
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            guard !Task.isCancelled,
                  let self,
                  self.playbackState == .queued(requestID) else { return }
            self.currentRequestID = nil
            self.currentUtterance = nil
            self.playbackState = .failed(requestID)
            self.synthesizer.stopSpeaking(at: .immediate)
            print("[TTS][ERROR] iOS 한국어 음성 시작 timeout request=\(self.logID(requestID))")
        }
    }

    @discardableResult
    private func configurePlaybackAudioSession() -> Bool {
        let session = AVAudioSession.sharedInstance()

        if session.category != .playback || session.mode != .spokenAudio {
            do {
                try session.setActive(false, options: [.notifyOthersOnDeactivation])
            } catch {
                let nsError = error as NSError
                print(
                    "[TTS][AUDIO][WARN] 이전 세션 비활성 실패 후 재구성 계속 "
                    + "domain=\(nsError.domain) code=\(nsError.code)"
                )
            }
        }

        do {
            try session.setCategory(
                .playback,
                mode: .spokenAudio,
                options: [.duckOthers, .allowBluetoothA2DP]
            )
            try session.setActive(true)

            let outputs = session.currentRoute.outputs
                .map { $0.portType.rawValue }
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
        utterance: AVSpeechUtterance,
        outcome: String
    ) {
        guard currentUtterance === utterance,
              let requestID = currentRequestID else { return }
        currentUtterance = nil
        currentRequestID = nil
        playbackState = .idle
        print("[TTS][INFO] iOS 한국어 음성 \(outcome) request=\(logID(requestID))")
    }

    private func logID(_ requestID: UUID) -> String {
        String(requestID.uuidString.prefix(8))
    }
}

extension TTSService: AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        didStart utterance: AVSpeechUtterance
    ) {
        Task { @MainActor [weak self, weak utterance] in
            guard let self, let utterance,
                  self.currentUtterance === utterance,
                  let requestID = self.currentRequestID else { return }
            self.playbackState = .speaking(requestID)
            print("[TTS][START] iOS 한국어 음성 재생 시작 request=\(self.logID(requestID))")
        }
    }

    nonisolated func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        didFinish utterance: AVSpeechUtterance
    ) {
        Task { @MainActor [weak self, weak utterance] in
            guard let self, let utterance else { return }
            self.finishSpeech(utterance: utterance, outcome: "재생 완료")
        }
    }

    nonisolated func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        didCancel utterance: AVSpeechUtterance
    ) {
        Task { @MainActor [weak self, weak utterance] in
            guard let self, let utterance else { return }
            self.finishSpeech(utterance: utterance, outcome: "재생 취소")
        }
    }
}
