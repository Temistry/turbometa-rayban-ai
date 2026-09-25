/*
 * Alibaba Qwen Omni 실시간 음성/영상 대화 서비스
 *
 * 예상된 사용자 종료와 실제 네트워크 장애를 구분해 불필요한
 * "Socket is not connected" 팝업을 막고, 기기 화면 로그에 원인을 남긴다.
 */

import AVFoundation
import Foundation
import UIKit

// MARK: - WebSocket events

enum OmniClientEvent: String {
    case sessionUpdate = "session.update"
    case inputAudioBufferAppend = "input_audio_buffer.append"
    case inputAudioBufferCommit = "input_audio_buffer.commit"
    case inputImageBufferAppend = "input_image_buffer.append"
    case responseCreate = "response.create"
}

enum OmniServerEvent: String {
    case sessionCreated = "session.created"
    case sessionUpdated = "session.updated"
    case inputAudioBufferSpeechStarted = "input_audio_buffer.speech_started"
    case inputAudioBufferSpeechStopped = "input_audio_buffer.speech_stopped"
    case inputAudioBufferCommitted = "input_audio_buffer.committed"
    case responseCreated = "response.created"
    case responseAudioTranscriptDelta = "response.audio_transcript.delta"
    case responseAudioTranscriptDone = "response.audio_transcript.done"
    case responseAudioDelta = "response.audio.delta"
    case responseAudioDone = "response.audio.done"
    case responseDone = "response.done"
    case conversationItemCreated = "conversation.item.created"
    case conversationItemInputAudioTranscriptionCompleted = "conversation.item.input_audio_transcription.completed"
    case error = "error"
}

final class OmniRealtimeService: NSObject {
    private var webSocket: URLSessionWebSocketTask?
    private var urlSession: URLSession?

    private let apiKey: String
    private let model = "qwen3-omni-flash-realtime"
    private var baseURL: String { APIProviderManager.staticLiveAIWebsocketURL }

    private var audioEngine: AVAudioEngine?
    private var playbackEngine: AVAudioEngine?
    private var playerNode: AVAudioPlayerNode?
    private let playbackFormat = AVAudioFormat(standardFormatWithSampleRate: 24_000, channels: 1)

    private var audioBuffer = Data()
    private var isCollectingAudio = false
    private var audioChunkCount = 0
    private let minimumChunksBeforePlayback = 2
    private var hasStartedPlaying = false
    private var isPlaybackEngineRunning = false

    var onTranscriptDelta: ((String) -> Void)?
    var onTranscriptDone: ((String) -> Void)?
    var onUserTranscript: ((String) -> Void)?
    var onAudioDelta: ((Data) -> Void)?
    var onAudioDone: (() -> Void)?
    var onSpeechStarted: (() -> Void)?
    var onSpeechStopped: (() -> Void)?
    var onError: ((String) -> Void)?
    var onConnected: (() -> Void)?
    var onFirstAudioSent: (() -> Void)?

    private var isRecording = false
    private var hasAudioBeenSent = false
    private var eventIDCounter = 0
    private var isIntentionalDisconnect = false
    private var hasEstablishedSession = false
    private var receiveLoopID = UUID()

    init(apiKey: String) {
        self.apiKey = apiKey
        super.init()
        setupAudioEngines()
    }

    // MARK: - Audio setup

    private func setupAudioEngines() {
        audioEngine = AVAudioEngine()
        setupPlaybackEngine()
    }

    private func setupPlaybackEngine() {
        let engine = AVAudioEngine()
        let node = AVAudioPlayerNode()

        guard let playbackFormat else {
            print("[Omni][ERROR] 24kHz mono 재생 포맷 생성 실패")
            return
        }

        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: playbackFormat)
        engine.prepare()

        playbackEngine = engine
        playerNode = node
        isPlaybackEngineRunning = false
        print("[Omni][AUDIO] 재생 엔진 초기화 sampleRate=24000 channels=1")
    }

    private func configureAudioSession() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(
            .playAndRecord,
            mode: .voiceChat,
            options: [.allowBluetooth, .allowBluetoothA2DP, .defaultToSpeaker]
        )
        try session.setActive(true, options: [.notifyOthersOnDeactivation])

        let inputs = session.currentRoute.inputs.map { "\($0.portType.rawValue):\($0.portName)" }.joined(separator: ",")
        let outputs = session.currentRoute.outputs.map { "\($0.portType.rawValue):\($0.portName)" }.joined(separator: ",")
        print("[Omni][AUDIO] 세션 활성 category=\(session.category.rawValue) mode=\(session.mode.rawValue) input=[\(inputs)] output=[\(outputs)] sampleRate=\(session.sampleRate)")
    }

    @discardableResult
    private func startPlaybackEngine() -> Bool {
        if isPlaybackEngineRunning { return true }
        if playbackEngine == nil || playerNode == nil {
            setupPlaybackEngine()
        }

        guard let playbackEngine, let playerNode else {
            print("[Omni][ERROR] 재생 엔진 또는 player node 없음")
            return false
        }

        do {
            try configureAudioSession()
            try playbackEngine.start()
            playerNode.play()
            isPlaybackEngineRunning = true
            print("[Omni][AUDIO] 재생 엔진 시작 성공")
            return true
        } catch {
            let nsError = error as NSError
            print("[Omni][ERROR] 재생 엔진 시작 실패 domain=\(nsError.domain) code=\(nsError.code) description=\(nsError.localizedDescription) userInfo=\(nsError.userInfo)")
            return false
        }
    }

    private func stopPlaybackEngine() {
        playerNode?.stop()
        playerNode?.reset()
        playbackEngine?.stop()
        isPlaybackEngineRunning = false
        audioBuffer.removeAll(keepingCapacity: true)
        audioChunkCount = 0
        hasStartedPlaying = false
        isCollectingAudio = false
        print("[Omni][AUDIO] 재생 엔진 중지 및 큐 정리")
    }

    // MARK: - Connection

    func connect() {
        guard !apiKey.isEmpty else {
            emitError("Live AI API Key가 설정되지 않았습니다")
            return
        }

        if let webSocket, webSocket.state == .running {
            print("[Omni][WARN] 이미 WebSocket이 실행 중이므로 연결 요청 무시")
            return
        }

        isIntentionalDisconnect = false
        hasEstablishedSession = false
        receiveLoopID = UUID()

        let urlString = "\(baseURL)?model=\(model)"
        guard let url = URL(string: urlString) else {
            emitError("Live AI 서버 주소가 올바르지 않습니다")
            print("[Omni][ERROR] 잘못된 WebSocket URL baseURL=\(baseURL)")
            return
        }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 15

        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 0
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData

        let delegateQueue = OperationQueue()
        delegateQueue.name = "com.turbometa.omni-websocket"
        delegateQueue.maxConcurrentOperationCount = 1
        urlSession = URLSession(configuration: configuration, delegate: self, delegateQueue: delegateQueue)

        let task = urlSession?.webSocketTask(with: request)
        task?.maximumMessageSize = 16 * 1024 * 1024
        webSocket = task
        task?.resume()

        print("[Omni][INFO] WebSocket 연결 시작 host=\(url.host ?? "-") model=\(model) endpoint=\(APIProviderManager.staticAlibabaEndpoint.rawValue)")
        receiveMessage(loopID: receiveLoopID)
    }

    func disconnect() {
        guard !isIntentionalDisconnect else { return }
        isIntentionalDisconnect = true
        hasEstablishedSession = false
        receiveLoopID = UUID()

        print("[Omni][INFO] 사용자가 Live AI 연결 종료 요청 socketState=\(String(describing: webSocket?.state))")
        stopRecording()
        stopPlaybackEngine()

        webSocket?.cancel(with: .goingAway, reason: nil)
        webSocket = nil
        urlSession?.invalidateAndCancel()
        urlSession = nil
    }

    // MARK: - Session configuration

    private func configureSession() {
        let voice = LanguageManager.staticTtsVoice
        let instructions = LiveAIModeManager.staticSystemPrompt

        let sessionConfig: [String: Any] = [
            "event_id": generateEventID(),
            "type": OmniClientEvent.sessionUpdate.rawValue,
            "session": [
                "modalities": ["text", "audio"],
                "voice": voice,
                "input_audio_format": "pcm16",
                "output_audio_format": "pcm24",
                "smooth_output": true,
                "instructions": instructions,
                "turn_detection": [
                    "type": "server_vad",
                    "threshold": 0.5,
                    "silence_duration_ms": 800
                ]
            ]
        ]

        print("[Omni][INFO] 한국어 세션 설정 전송 voice=\(voice) instructionLength=\(instructions.count)")
        sendEvent(sessionConfig, eventType: OmniClientEvent.sessionUpdate.rawValue)
    }

    // MARK: - Recording

    func startRecording() {
        guard !isRecording else { return }
        guard hasEstablishedSession else {
            print("[Omni][WARN] 세션 연결 전 녹음 시작 요청 무시")
            return
        }

        do {
            if let engine = audioEngine, engine.isRunning {
                engine.inputNode.removeTap(onBus: 0)
                engine.stop()
            }

            try configureAudioSession()

            if audioEngine == nil {
                audioEngine = AVAudioEngine()
            }
            guard let engine = audioEngine else {
                emitError("마이크 오디오 엔진을 만들지 못했습니다")
                return
            }

            let inputNode = engine.inputNode
            let inputFormat = inputNode.outputFormat(forBus: 0)
            print("[Omni][AUDIO] 녹음 포맷 sampleRate=\(inputFormat.sampleRate) channels=\(inputFormat.channelCount) commonFormat=\(inputFormat.commonFormat.rawValue)")

            inputNode.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
                self?.processAudioBuffer(buffer)
            }

            engine.prepare()
            try engine.start()
            isRecording = true
            print("[Omni][INFO] 마이크 녹음 시작")
        } catch {
            let nsError = error as NSError
            print("[Omni][ERROR] 녹음 시작 실패 domain=\(nsError.domain) code=\(nsError.code) description=\(nsError.localizedDescription) userInfo=\(nsError.userInfo)")
            emitError("마이크를 시작하지 못했습니다. \(nsError.localizedDescription)")
        }
    }

    func stopRecording() {
        guard isRecording else { return }

        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        isRecording = false
        hasAudioBeenSent = false
        print("[Omni][INFO] 마이크 녹음 중지")
    }

    private func processAudioBuffer(_ buffer: AVAudioPCMBuffer) {
        guard let floatChannelData = buffer.floatChannelData else {
            print("[Omni][WARN] 녹음 버퍼 floatChannelData 없음")
            return
        }

        let frameLength = Int(buffer.frameLength)
        guard frameLength > 0 else { return }

        let channel = floatChannelData.pointee
        var int16Data = [Int16](repeating: 0, count: frameLength)
        for index in 0..<frameLength {
            let sample = max(-1.0, min(1.0, channel[index]))
            int16Data[index] = Int16(sample * 32_767.0)
        }

        let data = Data(bytes: int16Data, count: frameLength * MemoryLayout<Int16>.size)
        sendAudioAppend(data.base64EncodedString())

        if !hasAudioBeenSent {
            hasAudioBeenSent = true
            print("[Omni][INFO] 첫 마이크 오디오 전송 bytes=\(data.count)")
            DispatchQueue.main.async { [weak self] in
                self?.onFirstAudioSent?()
            }
        }
    }

    // MARK: - Send events

    private func sendEvent(_ event: [String: Any], eventType: String) {
        guard let jsonData = try? JSONSerialization.data(withJSONObject: event),
              let jsonString = String(data: jsonData, encoding: .utf8) else {
            print("[Omni][ERROR] 이벤트 직렬화 실패 type=\(eventType)")
            return
        }

        guard let webSocket, webSocket.state == .running else {
            if !isIntentionalDisconnect {
                print("[Omni][ERROR] WebSocket이 실행 중이 아니어서 전송 실패 type=\(eventType) state=\(String(describing: self.webSocket?.state))")
            }
            return
        }

        webSocket.send(.string(jsonString)) { [weak self] error in
            guard let self, let error else { return }
            let nsError = error as NSError
            print("[Omni][ERROR] 이벤트 전송 실패 type=\(eventType) domain=\(nsError.domain) code=\(nsError.code) description=\(nsError.localizedDescription)")

            guard !self.isIntentionalDisconnect else { return }
            DispatchQueue.main.async {
                self.onError?("Live AI 전송 오류: \(nsError.localizedDescription)")
            }
        }
    }

    func sendAudioAppend(_ base64Audio: String) {
        sendEvent([
            "event_id": generateEventID(),
            "type": OmniClientEvent.inputAudioBufferAppend.rawValue,
            "audio": base64Audio
        ], eventType: OmniClientEvent.inputAudioBufferAppend.rawValue)
    }

    func sendImageAppend(_ image: UIImage) {
        guard let imageData = image.jpegData(compressionQuality: 0.6) else {
            print("[Omni][ERROR] 이미지 JPEG 압축 실패")
            return
        }

        print("[Omni][INFO] 현재 안경 프레임 전송 imageBytes=\(imageData.count)")
        sendEvent([
            "event_id": generateEventID(),
            "type": OmniClientEvent.inputImageBufferAppend.rawValue,
            "image": imageData.base64EncodedString()
        ], eventType: OmniClientEvent.inputImageBufferAppend.rawValue)
    }

    func commitAudioBuffer() {
        sendEvent([
            "event_id": generateEventID(),
            "type": OmniClientEvent.inputAudioBufferCommit.rawValue
        ], eventType: OmniClientEvent.inputAudioBufferCommit.rawValue)
    }

    // MARK: - Receive loop

    private func receiveMessage(loopID: UUID) {
        guard let webSocket else { return }
        webSocket.receive { [weak self] result in
            guard let self else { return }
            guard loopID == self.receiveLoopID else {
                print("[Omni][INFO] 이전 수신 루프 콜백 무시")
                return
            }

            switch result {
            case .success(let message):
                self.handleMessage(message)
                self.receiveMessage(loopID: loopID)

            case .failure(let error):
                let nsError = error as NSError
                let state = self.webSocket?.state
                let expected = self.isIntentionalDisconnect || state == .canceling || state == .completed
                print("[Omni][\(expected ? "INFO" : "ERROR")] 수신 종료 expected=\(expected) socketState=\(String(describing: state)) domain=\(nsError.domain) code=\(nsError.code) description=\(nsError.localizedDescription)")

                guard !expected else { return }
                DispatchQueue.main.async {
                    self.onError?("Live AI 연결이 끊겼습니다. \(nsError.localizedDescription) (\(nsError.domain) \(nsError.code))")
                }
            }
        }
    }

    private func handleMessage(_ message: URLSessionWebSocketTask.Message) {
        switch message {
        case .string(let text):
            handleServerEvent(text)
        case .data(let data):
            guard let text = String(data: data, encoding: .utf8) else {
                print("[Omni][ERROR] 바이너리 메시지를 UTF-8로 변환하지 못함 bytes=\(data.count)")
                return
            }
            handleServerEvent(text)
        @unknown default:
            print("[Omni][WARN] 알 수 없는 WebSocket 메시지 유형")
        }
    }

    private func handleServerEvent(_ jsonString: String) {
        guard let data = jsonString.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String else {
            print("[Omni][ERROR] 서버 이벤트 JSON 파싱 실패 bytes=\(jsonString.utf8.count)")
            return
        }

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }

            switch type {
            case OmniServerEvent.sessionCreated.rawValue,
                 OmniServerEvent.sessionUpdated.rawValue:
                let firstConnection = !self.hasEstablishedSession
                self.hasEstablishedSession = true
                print("[Omni][INFO] 세션 설정 완료 type=\(type) first=\(firstConnection)")
                if firstConnection {
                    self.onConnected?()
                }

            case OmniServerEvent.inputAudioBufferSpeechStarted.rawValue:
                print("[Omni][INFO] 사용자 발화 시작 감지")
                self.onSpeechStarted?()

            case OmniServerEvent.inputAudioBufferSpeechStopped.rawValue:
                print("[Omni][INFO] 사용자 발화 종료 감지")
                self.onSpeechStopped?()

            case OmniServerEvent.responseAudioTranscriptDelta.rawValue:
                if let delta = json["delta"] as? String {
                    // 대화 내용 자체는 개인정보일 수 있으므로 길이만 로그에 남긴다.
                    print("[Omni][INFO] AI 자막 조각 수신 length=\(delta.count)")
                    self.onTranscriptDelta?(delta)
                }

            case OmniServerEvent.responseAudioTranscriptDone.rawValue:
                let text = json["text"] as? String ?? ""
                print("[Omni][INFO] AI 자막 완료 length=\(text.count)")
                self.onTranscriptDone?(text)

            case OmniServerEvent.responseAudioDelta.rawValue:
                if let encodedAudio = json["delta"] as? String,
                   let audioData = Data(base64Encoded: encodedAudio),
                   !audioData.isEmpty {
                    self.onAudioDelta?(audioData)
                    self.handleAudioDelta(audioData)
                }

            case OmniServerEvent.responseAudioDone.rawValue:
                self.finishAudioResponse()

            case OmniServerEvent.conversationItemInputAudioTranscriptionCompleted.rawValue:
                if let transcript = json["transcript"] as? String {
                    print("[Omni][INFO] 사용자 음성 인식 완료 length=\(transcript.count)")
                    self.onUserTranscript?(transcript)
                }

            case OmniServerEvent.conversationItemCreated.rawValue,
                 OmniServerEvent.inputAudioBufferCommitted.rawValue,
                 OmniServerEvent.responseCreated.rawValue,
                 OmniServerEvent.responseDone.rawValue:
                print("[Omni][INFO] 서버 이벤트 type=\(type)")

            case OmniServerEvent.error.rawValue:
                let errorDictionary = json["error"] as? [String: Any]
                let code = errorDictionary?["code"].map(String.init(describing:)) ?? "-"
                let message = errorDictionary?["message"] as? String ?? "설명 없는 서버 오류"
                print("[Omni][ERROR] 서버 오류 code=\(code) message=\(message)")
                self.onError?("Live AI 서버 오류: \(message) (코드 \(code))")

            default:
                print("[Omni][INFO] 처리하지 않는 서버 이벤트 type=\(type)")
            }
        }
    }

    // MARK: - Audio playback

    private func handleAudioDelta(_ audioData: Data) {
        if !isCollectingAudio {
            isCollectingAudio = true
            audioBuffer.removeAll(keepingCapacity: true)
            audioChunkCount = 0
            hasStartedPlaying = false

            if isPlaybackEngineRunning {
                stopPlaybackEngine()
                setupPlaybackEngine()
            }
        }

        audioChunkCount += 1
        if !hasStartedPlaying {
            audioBuffer.append(audioData)
            if audioChunkCount >= minimumChunksBeforePlayback {
                hasStartedPlaying = true
                playAudio(audioBuffer)
                audioBuffer.removeAll(keepingCapacity: true)
            }
        } else {
            playAudio(audioData)
        }
    }

    private func finishAudioResponse() {
        isCollectingAudio = false
        if !audioBuffer.isEmpty {
            playAudio(audioBuffer)
            audioBuffer.removeAll(keepingCapacity: true)
        }

        print("[Omni][INFO] AI 오디오 응답 완료 chunks=\(audioChunkCount)")
        audioChunkCount = 0
        hasStartedPlaying = false
        onAudioDone?()
    }

    private func playAudio(_ audioData: Data) {
        guard !audioData.isEmpty,
              let playbackFormat,
              let pcmBuffer = createPCMBuffer(from: audioData, format: playbackFormat) else {
            print("[Omni][WARN] AI 오디오 PCM 변환 실패 bytes=\(audioData.count)")
            return
        }

        if !isPlaybackEngineRunning, !startPlaybackEngine() {
            emitError("AI 음성 재생 장치를 시작하지 못했습니다")
            return
        }

        guard let playerNode else { return }
        if !playerNode.isPlaying {
            playerNode.play()
        }
        playerNode.scheduleBuffer(pcmBuffer)
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

    // MARK: - Helpers

    private func generateEventID() -> String {
        eventIDCounter += 1
        return "event_\(eventIDCounter)_\(UUID().uuidString.prefix(8))"
    }

    private func emitError(_ message: String) {
        print("[Omni][ERROR] \(message)")
        DispatchQueue.main.async { [weak self] in
            self?.onError?(message)
        }
    }
}

// MARK: - URLSessionWebSocketDelegate

extension OmniRealtimeService: URLSessionWebSocketDelegate {
    func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didOpenWithProtocol protocol: String?
    ) {
        print("[Omni][INFO] WebSocket 열림 protocol=\(`protocol` ?? "-")")
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.isIntentionalDisconnect else { return }
            self.configureSession()
        }
    }

    func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
        reason: Data?
    ) {
        let reasonText = reason.flatMap { String(data: $0, encoding: .utf8) } ?? "-"
        let expected = isIntentionalDisconnect || closeCode == .goingAway || closeCode == .normalClosure
        print("[Omni][\(expected ? "INFO" : "ERROR")] WebSocket 닫힘 expected=\(expected) closeCode=\(closeCode.rawValue) reason=\(reasonText)")

        guard !expected else { return }
        DispatchQueue.main.async { [weak self] in
            self?.onError?("Live AI 연결이 종료되었습니다. 코드 \(closeCode.rawValue), 사유: \(reasonText)")
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error else { return }
        let nsError = error as NSError
        let expected = isIntentionalDisconnect || webSocket?.state == .canceling || webSocket?.state == .completed
        print("[Omni][\(expected ? "INFO" : "ERROR")] URLSession 작업 종료 expected=\(expected) domain=\(nsError.domain) code=\(nsError.code) description=\(nsError.localizedDescription)")

        guard !expected else { return }
        DispatchQueue.main.async { [weak self] in
            self?.onError?("Live AI 네트워크 오류: \(nsError.localizedDescription) (\(nsError.domain) \(nsError.code))")
        }
    }
}
