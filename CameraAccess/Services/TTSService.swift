/*
 * TTS Service
 * 퀵비전 음성 출력 서비스
 * OpenRouter는 iOS 시스템 TTS, Alibaba는 qwen3-tts-flash를 사용하며 실패 시 시스템 TTS로 폴백한다.
 */

import AVFoundation
import Foundation

@MainActor
class TTSService: NSObject, ObservableObject {
    static let shared = TTSService()

    @Published var isSpeaking = false

    private let baseURL = "https://dashscope.aliyuncs.com/api/v1/services/aigc/multimodal-generation/generation"
    private let model = "qwen3-tts-flash"

    private var voice: String { LanguageManager.staticTtsVoice }
    private var languageType: String { LanguageManager.staticApiLanguageCode }

    private var playbackEngine: AVAudioEngine?
    private var playerNode: AVAudioPlayerNode?
    private let playbackFormat = AVAudioFormat(standardFormatWithSampleRate: 24000, channels: 1)
    private var isPlaybackEngineRunning = false

    private var currentTask: Task<Void, Never>?
    private var systemSynthesizer: AVSpeechSynthesizer?

    private override init() {
        super.init()
        setupPlaybackEngine()
    }

    private func setupPlaybackEngine() {
        playbackEngine = AVAudioEngine()
        playerNode = AVAudioPlayerNode()

        guard let playbackEngine, let playerNode, let playbackFormat else {
            print("[TTS][ERROR] 재생 엔진 초기화 실패")
            return
        }

        playbackEngine.attach(playerNode)
        playbackEngine.connect(playerNode, to: playbackEngine.mainMixerNode, format: playbackFormat)
        playbackEngine.prepare()
        print("[TTS][INFO] 재생 엔진 초기화 완료 format=Float32 sampleRate=24000 channels=1")
    }

    private func logAudioRoute(_ prefix: String) {
        let session = AVAudioSession.sharedInstance()
        let outputs = session.currentRoute.outputs.map { "\($0.portType.rawValue):\($0.portName)" }.joined(separator: ", ")
        let inputs = session.currentRoute.inputs.map { "\($0.portType.rawValue):\($0.portName)" }.joined(separator: ", ")
        print("[TTS][AUDIO] \(prefix) category=\(session.category.rawValue) mode=\(session.mode.rawValue) sampleRate=\(session.sampleRate) outputVolume=\(session.outputVolume) inputs=[\(inputs)] outputs=[\(outputs)]")
    }

    private func configureAudioSession() {
        let audioSession = AVAudioSession.sharedInstance()
        do {
            logAudioRoute("설정 전")
            try audioSession.setCategory(.playAndRecord, mode: .voiceChat, options: [.allowBluetooth, .allowBluetoothA2DP])
            try audioSession.setPreferredSampleRate(24000)
            try audioSession.setActive(true, options: [.notifyOthersOnDeactivation])
            logAudioRoute("설정 후")
        } catch {
            print("[TTS][ERROR] AudioSession 설정 실패 domain=\((error as NSError).domain) code=\((error as NSError).code) description=\(error.localizedDescription) detail=\(error)")
        }
    }

    private func startPlaybackEngine() {
        guard let playbackEngine, !isPlaybackEngineRunning else { return }
        configureAudioSession()
        do {
            try playbackEngine.start()
            playerNode?.play()
            isPlaybackEngineRunning = true
            print("[TTS][INFO] 재생 엔진 시작 성공")
            logAudioRoute("재생 시작")
        } catch {
            print("[TTS][ERROR] 재생 엔진 시작 실패 domain=\((error as NSError).domain) code=\((error as NSError).code) description=\(error.localizedDescription) detail=\(error)")
        }
    }

    private func stopPlaybackEngine() {
        playerNode?.stop()
        playerNode?.reset()
        playbackEngine?.stop()
        isPlaybackEngineRunning = false
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
        configureAudioSession()
        print("[TTS][INFO] 음성 세션 사전 설정 완료")
    }

    func speak(_ text: String, apiKey: String? = nil) {
        currentTask?.cancel()
        stop()

        print("[TTS][INFO] speak 요청 provider=\(APIProviderManager.staticCurrentProvider.displayName) language=\(languageType) voice=\(voice) textLength=\(text.count)")

        if APIProviderManager.staticCurrentProvider == .openrouter {
            print("[TTS][INFO] OpenRouter 사용 중. iOS 시스템 TTS(ko-KR)로 재생")
            isSpeaking = true
            currentTask = Task {
                await fallbackToSystemTTS(text: text)
                isSpeaking = false
            }
            return
        }

        let key = apiKey ?? APIKeyManager.shared.getAPIKey(for: .alibaba)
        guard let finalKey = key, !finalKey.isEmpty else {
            print("[TTS][WARN] Alibaba API Key 없음. 시스템 TTS로 폴백")
            isSpeaking = true
            currentTask = Task {
                await fallbackToSystemTTS(text: text)
                isSpeaking = false
            }
            return
        }

        isSpeaking = true
        currentTask = Task {
            do {
                try await synthesizeAndPlay(text: text, apiKey: finalKey)
            } catch {
                if !Task.isCancelled {
                    let ns = error as NSError
                    print("[TTS][ERROR] Alibaba TTS 실패 domain=\(ns.domain) code=\(ns.code) description=\(ns.localizedDescription) userInfo=\(ns.userInfo)")
                    print("[TTS][INFO] 시스템 TTS(ko-KR)로 폴백")
                    await fallbackToSystemTTS(text: text)
                }
            }
            if !Task.isCancelled { isSpeaking = false }
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

    private func synthesizeAndPlay(text: String, apiKey: String) async throws {
        guard let url = URL(string: baseURL) else { throw TTSError.invalidResponse }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("enable", forHTTPHeaderField: "X-DashScope-SSE")
        request.timeoutInterval = 30

        let ttsRequest = TTSRequest(model: model, input: .init(text: text, voice: voice, language_type: languageType))
        request.httpBody = try JSONEncoder().encode(ttsRequest)
        print("[TTS][HTTP] request url=\(url.absoluteString) model=\(model) voice=\(voice) language_type=\(languageType) textLength=\(text.count)")

        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        guard let httpResponse = response as? HTTPURLResponse else { throw TTSError.invalidResponse }
        print("[TTS][HTTP] status=\(httpResponse.statusCode) headers=\(httpResponse.allHeaderFields)")
        guard httpResponse.statusCode == 200 else { throw TTSError.apiError(statusCode: httpResponse.statusCode) }

        playerNode?.stop()
        playerNode?.reset()
        if !isPlaybackEngineRunning { startPlaybackEngine() }
        playerNode?.play()
        guard isPlaybackEngineRunning else { throw TTSError.playbackFailed }

        var chunkCount = 0
        var totalBytes = 0
        var eventCount = 0

        for try await line in bytes.lines {
            if Task.isCancelled { return }
            guard line.hasPrefix("data:") else { continue }
            eventCount += 1
            let jsonString = String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)
            if jsonString == "[DONE]" { break }

            guard let jsonData = jsonString.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else {
                print("[TTS][WARN] SSE JSON 파싱 실패 event=\(eventCount) payload=\(jsonString.prefix(500))")
                continue
            }

            if let code = json["code"], let message = json["message"] {
                print("[TTS][SERVER_ERROR] code=\(code) message=\(message) payload=\(json)")
            }

            if let output = json["output"] as? [String: Any],
               let audio = output["audio"] as? [String: Any],
               let audioString = audio["data"] as? String,
               let audioData = Data(base64Encoded: audioString), !audioData.isEmpty {
                chunkCount += 1
                totalBytes += audioData.count
                if chunkCount == 1 { print("[TTS][INFO] 첫 오디오 청크 수신 bytes=\(audioData.count)") }
                playAudioChunk(audioData)
            }
        }

        if Task.isCancelled { return }
        print("[TTS][INFO] 스트림 종료 events=\(eventCount) audioChunks=\(chunkCount) totalAudioBytes=\(totalBytes)")
        guard chunkCount > 0 else { throw TTSError.noAudioData }
        await waitForPlaybackCompletion()
        print("[TTS][INFO] 음성 재생 완료")
    }

    private func playAudioChunk(_ audioData: Data) {
        guard !audioData.isEmpty else { return }
        guard let playerNode, let playbackFormat else {
            print("[TTS][ERROR] playerNode/playbackFormat 없음")
            return
        }
        guard let pcmBuffer = createPCMBuffer(from: audioData, format: playbackFormat) else {
            print("[TTS][ERROR] PCM buffer 생성 실패 bytes=\(audioData.count)")
            return
        }
        if !isPlaybackEngineRunning { startPlaybackEngine() }
        if !playerNode.isPlaying { playerNode.play() }
        playerNode.scheduleBuffer(pcmBuffer)
    }

    private func createPCMBuffer(from data: Data, format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let frameCount = data.count / 2
        guard frameCount > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frameCount)),
              let channelData = buffer.floatChannelData else { return nil }

        buffer.frameLength = AVAudioFrameCount(frameCount)
        data.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.baseAddress else { return }
            let int16Pointer = baseAddress.assumingMemoryBound(to: Int16.self)
            let floatData = channelData[0]
            for i in 0..<frameCount { floatData[i] = Float(int16Pointer[i]) / 32768.0 }
        }
        return buffer
    }

    private func waitForPlaybackCompletion() async {
        guard let playerNode else { return }
        while playerNode.isPlaying {
            if Task.isCancelled { return }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        try? await Task.sleep(nanoseconds: 300_000_000)
    }

    private func fallbackToSystemTTS(text: String) async {
        print("[TTS][SYSTEM] 시스템 TTS 시작 language=\(LanguageManager.staticSystemVoiceLanguage) textLength=\(text.count)")
        do {
            let audioSession = AVAudioSession.sharedInstance()
            try audioSession.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers, .allowBluetoothA2DP])
            try audioSession.setActive(true)
            logAudioRoute("시스템 TTS")
        } catch {
            let ns = error as NSError
            print("[TTS][ERROR] 시스템 TTS AudioSession 실패 domain=\(ns.domain) code=\(ns.code) description=\(ns.localizedDescription)")
        }

        systemSynthesizer = AVSpeechSynthesizer()
        guard let synthesizer = systemSynthesizer else { return }

        let utterance = AVSpeechUtterance(string: text)
        let voiceLanguage = LanguageManager.staticSystemVoiceLanguage
        let selectedVoice = AVSpeechSynthesisVoice(language: voiceLanguage)
        utterance.voice = selectedVoice
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        utterance.volume = 1.0
        utterance.pitchMultiplier = 1.0

        if let selectedVoice {
            print("[TTS][SYSTEM] voice 선택 성공 language=\(selectedVoice.language) name=\(selectedVoice.name) quality=\(selectedVoice.quality.rawValue)")
        } else {
            let installed = AVSpeechSynthesisVoice.speechVoices().filter { $0.language.hasPrefix("ko") }.map { "\($0.language):\($0.name)" }
            print("[TTS][ERROR] ko-KR 음성을 찾지 못함 installedKoreanVoices=\(installed)")
        }

        synthesizer.speak(utterance)
        try? await Task.sleep(nanoseconds: 150_000_000)
        print("[TTS][SYSTEM] speak 호출 후 isSpeaking=\(synthesizer.isSpeaking)")

        while synthesizer.isSpeaking {
            if Task.isCancelled {
                synthesizer.stopSpeaking(at: .immediate)
                systemSynthesizer = nil
                return
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }

        print("[TTS][SYSTEM] 시스템 TTS 재생 완료")
        systemSynthesizer = nil
    }
}

enum TTSError: LocalizedError {
    case noAPIKey
    case invalidResponse
    case apiError(statusCode: Int)
    case noAudioData
    case playbackFailed

    var errorDescription: String? {
        switch self {
        case .noAPIKey: return "API Key가 설정되지 않았습니다"
        case .invalidResponse: return "잘못된 응답입니다"
        case .apiError(let statusCode): return "API 오류: \(statusCode)"
        case .noAudioData: return "오디오 데이터를 받지 못했습니다"
        case .playbackFailed: return "오디오 재생에 실패했습니다"
        }
    }
}
