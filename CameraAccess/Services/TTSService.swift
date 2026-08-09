/*
 * 퀵비전 한국어 음성 출력 서비스
 *
 * Alibaba qwen3-tts-flash를 우선 사용하고 실패하면 iOS ko-KR 시스템 음성으로 폴백한다.
 * 음성 재생용 세션은 녹음 세션과 분리해 수화기 대신 스피커 또는 Bluetooth A2DP로 출력한다.
 */

import AVFoundation
import Foundation

@MainActor
final class TTSService: NSObject, ObservableObject {
    static let shared = TTSService()

    @Published var isSpeaking = false

    private let model = "qwen3-tts-flash"
    private var voice: String { LanguageManager.staticTtsVoice }
    private var languageType: String { LanguageManager.staticApiLanguageCode }

    private var baseURL: String {
        switch APIProviderManager.staticAlibabaEndpoint {
        case .beijing:
            return "https://dashscope.aliyuncs.com/api/v1/services/aigc/multimodal-generation/generation"
        case .singapore:
            return "https://dashscope-intl.aliyuncs.com/api/v1/services/aigc/multimodal-generation/generation"
        }
    }

    private var playbackEngine: AVAudioEngine?
    private var playerNode: AVAudioPlayerNode?
    private let playbackFormat = AVAudioFormat(standardFormatWithSampleRate: 24_000, channels: 1)
    private var isPlaybackEngineRunning = false
    private var pendingBufferCount = 0

    private var currentTask: Task<Void, Never>?
    private var systemSynthesizer: AVSpeechSynthesizer?

    private override init() {
        super.init()
        setupPlaybackEngine()
    }

    // MARK: - Audio engine

    private func setupPlaybackEngine() {
        let engine = AVAudioEngine()
        let node = AVAudioPlayerNode()

        guard let playbackFormat else {
            print("[TTS][ERROR] 24kHz mono 재생 포맷 생성 실패")
            return
        }

        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: playbackFormat)
        engine.prepare()

        playbackEngine = engine
        playerNode = node
        isPlaybackEngineRunning = false
        pendingBufferCount = 0
        print("[TTS][INFO] 재생 엔진 초기화 format=Float32 sampleRate=24000 channels=1")
    }

    private func logAudioRoute(_ prefix: String) {
        let session = AVAudioSession.sharedInstance()
        let outputs = session.currentRoute.outputs
            .map { "\($0.portType.rawValue):\($0.portName)" }
            .joined(separator: ", ")
        let inputs = session.currentRoute.inputs
            .map { "\($0.portType.rawValue):\($0.portName)" }
            .joined(separator: ", ")
        print("[TTS][AUDIO] \(prefix) category=\(session.category.rawValue) mode=\(session.mode.rawValue) sampleRate=\(session.sampleRate) outputVolume=\(session.outputVolume) inputs=[\(inputs)] outputs=[\(outputs)]")
    }

    @discardableResult
    private func configurePlaybackAudioSession() -> Bool {
        let session = AVAudioSession.sharedInstance()
        do {
            logAudioRoute("재생 세션 설정 전")
            try session.setCategory(
                .playback,
                mode: .spokenAudio,
                options: [.duckOthers, .allowBluetoothA2DP]
            )
            try session.setPreferredSampleRate(24_000)
            try session.setActive(true, options: [.notifyOthersOnDeactivation])
            logAudioRoute("재생 세션 설정 후")

            let hasOutput = !session.currentRoute.outputs.isEmpty
            if !hasOutput {
                print("[TTS][ERROR] 활성 오디오 출력 경로가 없습니다")
            }
            return hasOutput
        } catch {
            let nsError = error as NSError
            print("[TTS][ERROR] AudioSession 설정 실패 domain=\(nsError.domain) code=\(nsError.code) description=\(nsError.localizedDescription) userInfo=\(nsError.userInfo)")
            return false
        }
    }

    @discardableResult
    private func startPlaybackEngine() -> Bool {
        if isPlaybackEngineRunning {
            return true
        }

        guard configurePlaybackAudioSession() else {
            return false
        }

        if playbackEngine == nil || playerNode == nil {
            setupPlaybackEngine()
        }

        guard let playbackEngine, let playerNode else {
            print("[TTS][ERROR] 재생 엔진 또는 player node가 없습니다")
            return false
        }

        do {
            try playbackEngine.start()
            playerNode.play()
            isPlaybackEngineRunning = true
            print("[TTS][INFO] 재생 엔진 시작 성공")
            logAudioRoute("재생 엔진 시작")
            return true
        } catch {
            let nsError = error as NSError
            print("[TTS][ERROR] 재생 엔진 시작 실패 domain=\(nsError.domain) code=\(nsError.code) description=\(nsError.localizedDescription) userInfo=\(nsError.userInfo)")
            isPlaybackEngineRunning = false
            return false
        }
    }

    private func stopPlaybackEngine() {
        playerNode?.stop()
        playerNode?.reset()
        playbackEngine?.stop()
        isPlaybackEngineRunning = false
        pendingBufferCount = 0
    }

    struct TTSRequest: Codable {
        let model: String
        let input: Input

        struct Input: Codable {
            let text: String
            let voice: String
            let language_type: String
        }
    }

    func prepareAudioSession() {
        _ = configurePlaybackAudioSession()
        print("[TTS][INFO] 한국어 음성 재생 세션 사전 설정 완료")
    }

    // MARK: - Public playback

    func speak(_ text: String, apiKey: String? = nil) {
        let normalizedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedText.isEmpty else {
            print("[TTS][WARN] 빈 문자열 음성 요청 무시")
            return
        }

        stop()
        print("[TTS][INFO] 음성 요청 provider=\(APIProviderManager.staticCurrentProvider.displayName) endpoint=\(APIProviderManager.staticAlibabaEndpoint.rawValue) language=\(languageType) voice=\(voice) textLength=\(normalizedText.count)")

        if APIProviderManager.staticCurrentProvider == .openrouter {
            startSystemTTS(text: normalizedText, reason: "OpenRouter 선택")
            return
        }

        let key = apiKey
            ?? APIKeyManager.shared.getAPIKey(
                for: .alibaba,
                endpoint: APIProviderManager.staticAlibabaEndpoint
            )

        guard let finalKey = key, !finalKey.isEmpty else {
            startSystemTTS(text: normalizedText, reason: "Alibaba API Key 없음")
            return
        }

        isSpeaking = true
        currentTask = Task { [weak self] in
            guard let self else { return }

            do {
                try await self.synthesizeAndPlay(text: normalizedText, apiKey: finalKey)
            } catch is CancellationError {
                print("[TTS][INFO] 음성 작업 취소")
            } catch {
                if !Task.isCancelled {
                    let nsError = error as NSError
                    print("[TTS][ERROR] Alibaba TTS 실패 domain=\(nsError.domain) code=\(nsError.code) description=\(nsError.localizedDescription) userInfo=\(nsError.userInfo)")
                    await self.fallbackToSystemTTS(text: normalizedText, reason: "Alibaba TTS 실패")
                }
            }

            if !Task.isCancelled {
                self.isSpeaking = false
                self.currentTask = nil
            }
        }
    }

    func stop() {
        currentTask?.cancel()
        currentTask = nil
        systemSynthesizer?.stopSpeaking(at: .immediate)
        systemSynthesizer = nil
        stopPlaybackEngine()
        isSpeaking = false
        print("[TTS][INFO] 음성 재생 중지")
    }

    private func startSystemTTS(text: String, reason: String) {
        print("[TTS][INFO] iOS 시스템 TTS(ko-KR) 사용 reason=\(reason)")
        isSpeaking = true
        currentTask = Task { [weak self] in
            guard let self else { return }
            await self.fallbackToSystemTTS(text: text, reason: reason)
            if !Task.isCancelled {
                self.isSpeaking = false
                self.currentTask = nil
            }
        }
    }

    // MARK: - Alibaba HTTP/SSE

    private func synthesizeAndPlay(text: String, apiKey: String) async throws {
        guard let url = URL(string: baseURL) else {
            throw TTSError.invalidResponse
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("enable", forHTTPHeaderField: "X-DashScope-SSE")
        request.timeoutInterval = 30

        let body = TTSRequest(
            model: model,
            input: .init(text: text, voice: voice, language_type: languageType)
        )
        request.httpBody = try JSONEncoder().encode(body)

        let startedAt = Date()
        print("[TTS][HTTP] POST host=\(url.host ?? "-") model=\(model) voice=\(voice) language=\(languageType) requestBytes=\(request.httpBody?.count ?? 0)")

        let bytes: URLSession.AsyncBytes
        let response: URLResponse
        do {
            (bytes, response) = try await URLSession.shared.bytes(for: request)
        } catch {
            let nsError = error as NSError
            print("[TTS][ERROR] HTTP 연결 실패 domain=\(nsError.domain) code=\(nsError.code) description=\(nsError.localizedDescription)")
            throw error
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw TTSError.invalidResponse
        }

        let requestID = httpResponse.value(forHTTPHeaderField: "x-request-id")
            ?? httpResponse.value(forHTTPHeaderField: "x-dashscope-request-id")
            ?? "-"
        let elapsedMs = Int(Date().timeIntervalSince(startedAt) * 1_000)
        print("[TTS][HTTP] 응답 status=\(httpResponse.statusCode) elapsedMs=\(elapsedMs) requestID=\(requestID) contentType=\(httpResponse.value(forHTTPHeaderField: "Content-Type") ?? "-")")

        guard (200..<300).contains(httpResponse.statusCode) else {
            throw TTSError.apiError(statusCode: httpResponse.statusCode, requestID: requestID)
        }

        stopPlaybackEngine()
        setupPlaybackEngine()
        guard startPlaybackEngine() else {
            throw TTSError.playbackFailed
        }

        var eventCount = 0
        var audioChunkCount = 0
        var scheduledChunkCount = 0
        var totalAudioBytes = 0

        for try await line in bytes.lines {
            try Task.checkCancellation()
            guard line.hasPrefix("data:") else { continue }

            eventCount += 1
            let payload = String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)
            if payload == "[DONE]" { break }

            guard let jsonData = payload.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else {
                print("[TTS][WARN] SSE JSON 파싱 실패 event=\(eventCount) payloadLength=\(payload.count)")
                continue
            }

            if let code = json["code"], let message = json["message"] {
                print("[TTS][SERVER_ERROR] code=\(code) message=\(message) requestID=\(requestID)")
            }

            guard let output = json["output"] as? [String: Any],
                  let audio = output["audio"] as? [String: Any],
                  let encodedAudio = audio["data"] as? String,
                  let audioData = Data(base64Encoded: encodedAudio),
                  !audioData.isEmpty else {
                continue
            }

            audioChunkCount += 1
            totalAudioBytes += audioData.count
            if scheduleAudioChunk(audioData) {
                scheduledChunkCount += 1
            }

            if audioChunkCount == 1 {
                print("[TTS][INFO] 첫 오디오 청크 수신 bytes=\(audioData.count)")
            }
        }

        try Task.checkCancellation()
        print("[TTS][INFO] SSE 종료 events=\(eventCount) receivedChunks=\(audioChunkCount) scheduledChunks=\(scheduledChunkCount) totalAudioBytes=\(totalAudioBytes) pendingBuffers=\(pendingBufferCount)")

        guard scheduledChunkCount > 0 else {
            throw TTSError.noAudioData
        }

        try await waitForPlaybackCompletion(timeout: 45)
        stopPlaybackEngine()
        print("[TTS][INFO] Alibaba 한국어 음성 재생 완료")
    }

    @discardableResult
    private func scheduleAudioChunk(_ audioData: Data) -> Bool {
        guard !audioData.isEmpty,
              let playerNode,
              let playbackFormat,
              let pcmBuffer = createPCMBuffer(from: audioData, format: playbackFormat) else {
            print("[TTS][ERROR] 오디오 청크를 PCM 버퍼로 변환하지 못함 bytes=\(audioData.count)")
            return false
        }

        if !isPlaybackEngineRunning, !startPlaybackEngine() {
            return false
        }
        if !playerNode.isPlaying {
            playerNode.play()
        }

        pendingBufferCount += 1
        playerNode.scheduleBuffer(
            pcmBuffer,
            completionCallbackType: .dataPlayedBack
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.pendingBufferCount = max(0, self.pendingBufferCount - 1)
                if self.pendingBufferCount == 0 {
                    print("[TTS][AUDIO] 예약된 모든 PCM 버퍼 재생 완료")
                }
            }
        }
        return true
    }

    private func createPCMBuffer(from data: Data, format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let frameCount = data.count / MemoryLayout<Int16>.size
        guard frameCount > 0,
              let buffer = AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: AVAudioFrameCount(frameCount)
              ),
              let channelData = buffer.floatChannelData else {
            return nil
        }

        buffer.frameLength = AVAudioFrameCount(frameCount)
        data.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.baseAddress else { return }
            let int16Pointer = baseAddress.assumingMemoryBound(to: Int16.self)
            let floatData = channelData[0]
            for index in 0..<frameCount {
                floatData[index] = Float(Int16(littleEndian: int16Pointer[index])) / 32_768.0
            }
        }
        return buffer
    }

    private func waitForPlaybackCompletion(timeout: TimeInterval) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while pendingBufferCount > 0 {
            try Task.checkCancellation()
            if Date() >= deadline {
                print("[TTS][ERROR] 오디오 재생 완료 대기 시간 초과 pendingBuffers=\(pendingBufferCount) timeout=\(timeout)s")
                throw TTSError.playbackTimeout
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    // MARK: - iOS Korean fallback

    private func fallbackToSystemTTS(text: String, reason: String) async {
        print("[TTS][SYSTEM] 시작 language=\(LanguageManager.staticSystemVoiceLanguage) reason=\(reason) textLength=\(text.count)")
        _ = configurePlaybackAudioSession()

        systemSynthesizer = AVSpeechSynthesizer()
        guard let synthesizer = systemSynthesizer else {
            print("[TTS][ERROR] AVSpeechSynthesizer 생성 실패")
            return
        }

        let voiceLanguage = LanguageManager.staticSystemVoiceLanguage
        let utterance = AVSpeechUtterance(string: text)
        let selectedVoice = AVSpeechSynthesisVoice(language: voiceLanguage)
        utterance.voice = selectedVoice
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        utterance.volume = 1.0
        utterance.pitchMultiplier = 1.0

        if let selectedVoice {
            print("[TTS][SYSTEM] 한국어 음성 선택 language=\(selectedVoice.language) name=\(selectedVoice.name) quality=\(selectedVoice.quality.rawValue)")
        } else {
            let installedVoices = AVSpeechSynthesisVoice.speechVoices()
                .filter { $0.language.hasPrefix("ko") }
                .map { "\($0.language):\($0.name)" }
            print("[TTS][ERROR] ko-KR 음성을 찾지 못함 installedKoreanVoices=\(installedVoices)")
        }

        synthesizer.speak(utterance)
        try? await Task.sleep(nanoseconds: 150_000_000)
        print("[TTS][SYSTEM] speak 호출 isSpeaking=\(synthesizer.isSpeaking)")

        while synthesizer.isSpeaking {
            if Task.isCancelled {
                synthesizer.stopSpeaking(at: .immediate)
                systemSynthesizer = nil
                return
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }

        print("[TTS][SYSTEM] 한국어 음성 재생 완료")
        systemSynthesizer = nil
    }
}

enum TTSError: LocalizedError {
    case noAPIKey
    case invalidResponse
    case apiError(statusCode: Int, requestID: String)
    case noAudioData
    case playbackFailed
    case playbackTimeout

    var errorDescription: String? {
        switch self {
        case .noAPIKey:
            return "API Key가 설정되지 않았습니다"
        case .invalidResponse:
            return "잘못된 음성 API 응답입니다"
        case .apiError(let statusCode, let requestID):
            let requestSuffix = requestID == "-" ? "" : " 요청 ID: \(requestID)"
            return "음성 API 오류 \(statusCode)\(requestSuffix)"
        case .noAudioData:
            return "한국어 오디오 데이터를 받지 못했습니다"
        case .playbackFailed:
            return "오디오 재생 장치를 시작하지 못했습니다"
        case .playbackTimeout:
            return "오디오 재생 완료 대기 시간이 초과되었습니다"
        }
    }
}
