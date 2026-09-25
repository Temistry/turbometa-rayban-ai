/*
 * 퀵비전 한국어 음성 출력 서비스
 *
 * AI 호출은 Google Gemini로 통일하고, 짧은 퀵비전 결과 낭독은 네트워크와 별도
 * 인증값이 필요 없는 iOS ko-KR 시스템 음성을 사용한다.
 */

import AVFoundation
import Foundation

/// 귓속말을 들려줄 귀. 스테레오 출력(안경·에어팟 A2DP)일 때만 한쪽으로 보낼 수 있다.
enum WhisperSide: String, CaseIterable, Identifiable {
    case right
    case left
    case both

    static let storageKey = "meeting.whisperSide"

    var id: String { rawValue }
    var titleKey: String { "settings.whisper.\(rawValue)" }

    var pan: Float {
        switch self {
        case .right: return 1
        case .left: return -1
        case .both: return 0
        }
    }

    static func resolve(stored: String?) -> WhisperSide {
        stored.flatMap(WhisperSide.init(rawValue:)) ?? .right
    }

    static var current: WhisperSide {
        resolve(stored: UserDefaults.standard.string(forKey: storageKey))
    }
}

/// 합성 음성 버퍼를 받아 한쪽 채널로만 재생한다. 버퍼 순서를 지키려고 전용 직렬 큐에서 다룬다.
final class PannedSpeechPlayer {
    private let queue = DispatchQueue(label: "tts.panned-speech")
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var connectedFormat: AVAudioFormat?
    private var token = UUID()
    private var pending = 0
    private var synthesisDone = false
    private var started = false
    private var pan: Float = 0
    private var volume: Float = 1

    /// 메인 스레드에서 호출된다.
    var onStart: (() -> Void)?
    /// 메인 스레드에서 호출된다. 참이면 끝까지 재생했다.
    var onFinish: ((Bool) -> Void)?

    init() {
        engine.attach(player)
    }

    func begin(pan: Float, volume: Float) -> UUID {
        let newToken = UUID()
        queue.sync {
            resetPlayback()
            token = newToken
            self.pan = pan
            self.volume = volume
        }
        return newToken
    }

    func append(_ buffer: AVAudioPCMBuffer, token: UUID) {
        queue.async { [weak self] in
            guard let self, token == self.token else { return }
            guard buffer.frameLength > 0 else {
                self.synthesisDone = true
                if self.pending == 0 { self.complete(success: self.started) }
                return
            }
            guard let floatBuffer = Self.floatBuffer(from: buffer) else {
                self.complete(success: false)
                return
            }
            if self.connectedFormat != floatBuffer.format {
                self.engine.stop()
                self.engine.disconnectNodeOutput(self.player)
                self.engine.connect(self.player, to: self.engine.mainMixerNode, format: floatBuffer.format)
                self.connectedFormat = floatBuffer.format
            }
            self.player.pan = self.pan
            self.player.volume = self.volume
            if !self.engine.isRunning {
                do {
                    self.engine.prepare()
                    try self.engine.start()
                } catch {
                    DeveloperConsole.shared.log(.warning, category: "MeetingTTS", "panned engine failed code=\((error as NSError).code)")
                    self.complete(success: false)
                    return
                }
            }
            self.pending += 1
            self.player.scheduleBuffer(floatBuffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
                self?.queue.async {
                    guard let self, token == self.token else { return }
                    self.pending -= 1
                    if self.synthesisDone && self.pending == 0 { self.complete(success: true) }
                }
            }
            if !self.player.isPlaying { self.player.play() }
            if !self.started {
                self.started = true
                DispatchQueue.main.async { [weak self] in self?.onStart?() }
            }
        }
    }

    func stop() {
        queue.async { [weak self] in
            self?.token = UUID()
            self?.resetPlayback()
        }
    }

    /// 합성이 끝났다는 신호(마지막 빈 버퍼가 오지 않는 경우 대비).
    func finishSynthesis(token: UUID) {
        queue.async { [weak self] in
            guard let self, token == self.token, !self.synthesisDone else { return }
            self.synthesisDone = true
            if self.pending == 0 { self.complete(success: self.started) }
        }
    }

    private func complete(success: Bool) {
        token = UUID()
        resetPlayback()
        DispatchQueue.main.async { [weak self] in self?.onFinish?(success) }
    }

    private func resetPlayback() {
        player.stop()
        if engine.isRunning { engine.stop() }
        pending = 0
        synthesisDone = false
        started = false
    }

    private static func floatBuffer(from buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        if buffer.format.commonFormat == .pcmFormatFloat32, !buffer.format.isInterleaved {
            return buffer
        }
        guard let target = AVAudioFormat(standardFormatWithSampleRate: buffer.format.sampleRate,
                                         channels: buffer.format.channelCount),
              let converter = AVAudioConverter(from: buffer.format, to: target),
              let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: buffer.frameLength) else {
            return nil
        }
        do {
            try converter.convert(to: output, from: buffer)
            return output
        } catch {
            return nil
        }
    }
}

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
    private let pannedPlayer = PannedSpeechPlayer()
    private var pannedRequestID: UUID?
    private var pannedUtterance: AVSpeechUtterance?
    private var pannedToken: UUID?
    /// 한쪽 귀 재생이 이 시간 안에 끝나지 않으면 강제로 끝낸다(귓속말이 막히지 않게).
    static let pannedWatchdog: TimeInterval = 20

    /// 한쪽 귀로 보낼 수 있는 스테레오 출력인지.
    nonisolated static func supportsStereoPan(outputs: [AVAudioSession.Port]) -> Bool {
        outputs.contains { $0 == .bluetoothA2DP || $0 == .headphones || $0 == .bluetoothLE }
    }

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
    /// 회의 통역기 귓속말처럼 낮은 음량 재생이 필요할 때 volume을 지정한다.
    @discardableResult
    func enqueue(_ text: String, volume: Float = 1.0, preserveRecordingSession: Bool = false, pan: Float = 0) -> UUID? {
        let normalizedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedText.isEmpty else {
            print("[TTS][WARN] 빈 문자열 음성 요청 무시")
            return nil
        }

        stop()
        let audioReady = preserveRecordingSession
            ? AVAudioSession.sharedInstance().category == .playAndRecord
            : configurePlaybackAudioSession()
        guard audioReady else {
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
        DeveloperConsole.shared.log(.info, category: "MeetingTTS", "queued duplex=\(preserveRecordingSession) outputs=\(AVAudioSession.sharedInstance().currentRoute.outputs.map { $0.portType.rawValue }.joined(separator: ",")) chars=\(normalizedText.count)")
        let utterance = AVSpeechUtterance(string: normalizedText)
        utterance.voice = koreanVoice
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        utterance.volume = min(max(volume, 0), 1)
        utterance.pitchMultiplier = 1.0

        let outputs = AVAudioSession.sharedInstance().currentRoute.outputs.map(\.portType)
        if pan != 0, preserveRecordingSession, Self.supportsStereoPan(outputs: outputs) {
            startPannedSpeech(utterance, requestID: requestID, pan: pan)
            return requestID
        }

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

    /// 합성 결과를 버퍼로 받아 한쪽 귀로만 재생한다. 상태 흐름은 일반 재생과 같다(대기 → 재생 → 완료/실패).
    private func startPannedSpeech(_ utterance: AVSpeechUtterance, requestID: UUID, pan: Float) {
        currentRequestID = requestID
        currentUtterance = nil
        pannedRequestID = requestID
        playbackState = .queued(requestID)
        scheduleStartTimeout(requestID: requestID)
        print("[TTS][QUEUE] 한쪽 귀 재생 요청 request=\(logID(requestID)) pan=\(pan)")

        let player = pannedPlayer
        let token = player.begin(pan: pan, volume: utterance.volume)
        pannedUtterance = utterance
        pannedToken = token
        player.onStart = { [weak self] in
            guard let self, self.pannedRequestID == requestID else { return }
            self.playbackState = .speaking(requestID)
        }
        player.onFinish = { [weak self] success in
            guard let self, self.pannedRequestID == requestID else { return }
            self.pannedRequestID = nil
            self.currentRequestID = nil
            self.playbackState = success ? .idle : .failed(requestID)
            print("[TTS][INFO] 한쪽 귀 재생 \(success ? "완료" : "실패") request=\(self.logID(requestID))")
        }
        synthesizer.write(utterance) { buffer in
            guard let pcm = buffer as? AVAudioPCMBuffer else { return }
            player.append(pcm, token: token)
        }
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.pannedWatchdog * 1_000_000_000))
            guard let self, self.pannedRequestID == requestID else { return }
            print("[TTS][WARN] 한쪽 귀 재생 시간 초과, 강제 종료 request=\(self.logID(requestID))")
            self.pannedRequestID = nil
            self.currentRequestID = nil
            self.pannedPlayer.stop()
            self.playbackState = .idle
        }
    }

    func stop() {
        if pannedRequestID != nil {
            pannedRequestID = nil
            pannedPlayer.stop()
        }
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
            if self.pannedRequestID == requestID {
                self.pannedRequestID = nil
                self.pannedPlayer.stop()
            }
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
                options: []
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
                + "code=\(nsError.code)"
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
            if self.pannedUtterance === utterance, let token = self.pannedToken {
                self.pannedUtterance = nil
                self.pannedPlayer.finishSynthesis(token: token)
                return
            }
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
