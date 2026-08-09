/*
 * Google Gemini Live WebSocket service.
 *
 * Uses the current raw WebSocket message shape for Gemini Live, keeps Korean
 * system instructions, redacts the API key from logs, and distinguishes an
 * intentional user close from a real socket failure.
 */

import AVFoundation
import Foundation
import UIKit

final class GeminiLiveService: NSObject {
    private var webSocket: URLSessionWebSocketTask?
    private var urlSession: URLSession?

    private let apiKey: String
    private let model: String

    private var audioEngine: AVAudioEngine?
    private var playbackEngine: AVAudioEngine?
    private var playerNode: AVAudioPlayerNode?
    private let playbackAudioFormat = AVAudioFormat(standardFormatWithSampleRate: 24_000, channels: 1)
    private let recordTargetFormat = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)
    private var recordConverter: AVAudioConverter?

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
    private var isSessionConfigured = false
    private var isIntentionalDisconnect = false
    private var receiveLoopID = UUID()

    init(apiKey: String, model: String? = nil) {
        self.apiKey = apiKey
        self.model = model ?? "gemini-3.1-flash-live-preview"
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

        guard let playbackAudioFormat else {
            print("[Gemini][ERROR] 24kHz mono 재생 포맷 생성 실패")
            return
        }

        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: playbackAudioFormat)
        engine.prepare()

        playbackEngine = engine
        playerNode = node
        isPlaybackEngineRunning = false
        print("[Gemini][AUDIO] 재생 엔진 초기화 sampleRate=24000 channels=1")
    }

    private func configureAudioSession() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(
            .playAndRecord,
            mode: .voiceChat,
            options: [.allowBluetooth, .allowBluetoothA2DP, .defaultToSpeaker]
        )
        try session.setActive(true, options: [.notifyOthersOnDeactivation])

        let inputs = session.currentRoute.inputs
            .map { "\($0.portType.rawValue):\($0.portName)" }
            .joined(separator: ",")
        let outputs = session.currentRoute.outputs
            .map { "\($0.portType.rawValue):\($0.portName)" }
            .joined(separator: ",")
        print("[Gemini][AUDIO] 세션 활성 input=[\(inputs)] output=[\(outputs)] sampleRate=\(session.sampleRate)")
    }

    @discardableResult
    private func startPlaybackEngine() -> Bool {
        if isPlaybackEngineRunning { return true }
        if playbackEngine == nil || playerNode == nil {
            setupPlaybackEngine()
        }

        guard let playbackEngine, let playerNode else {
            print("[Gemini][ERROR] 재생 엔진 또는 player node 없음")
            return false
        }

        do {
            try configureAudioSession()
            try playbackEngine.start()
            playerNode.play()
            isPlaybackEngineRunning = true
            print("[Gemini][AUDIO] 재생 엔진 시작 성공")
            return true
        } catch {
            let nsError = error as NSError
            print("[Gemini][ERROR] 재생 엔진 시작 실패 domain=\(nsError.domain) code=\(nsError.code) description=\(nsError.localizedDescription) userInfo=\(nsError.userInfo)")
            return false
        }
    }

    private func stopPlaybackEngine() {
        playerNode?.stop()
        playerNode?.reset()
        playbackEngine?.stop()
        isPlaybackEngineRunning = false
        audioBuffer.removeAll(keepingCapacity: true)
        isCollectingAudio = false
        audioChunkCount = 0
        hasStartedPlaying = false
        print("[Gemini][AUDIO] 재생 엔진 중지 및 큐 정리")
    }

    // MARK: - Connection

    func connect() {
        guard !apiKey.isEmpty else {
            emitError("Google Gemini API Key가 설정되지 않았습니다")
            return
        }

        if let webSocket, webSocket.state == .running {
            print("[Gemini][WARN] 이미 WebSocket이 실행 중이므로 연결 요청 무시")
            return
        }

        isIntentionalDisconnect = false
        isSessionConfigured = false
        receiveLoopID = UUID()

        var components = URLComponents(
            string: "wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent"
        )
        components?.queryItems = [URLQueryItem(name: "key", value: apiKey)]

        guard let url = components?.url else {
            emitError("Gemini Live 서버 주소를 만들지 못했습니다")
            return
        }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 0
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData

        let delegateQueue = OperationQueue()
        delegateQueue.name = "com.turbometa.gemini-live"
        delegateQueue.maxConcurrentOperationCount = 1
        urlSession = URLSession(configuration: configuration, delegate: self, delegateQueue: delegateQueue)

        let task = urlSession?.webSocketTask(with: url)
        task?.maximumMessageSize = 16 * 1024 * 1024
        webSocket = task
        task?.resume()

        // The API key is deliberately omitted. The raw Gemini Live API requires it
        // in the WebSocket query string, which is exactly where humans historically
        // decided secrets should live.
        print("[Gemini][INFO] WebSocket 연결 시작 host=\(url.host ?? "-") model=\(model) apiKeyConfigured=true")
        receiveMessage(loopID: receiveLoopID)
    }

    func disconnect() {
        guard !isIntentionalDisconnect else { return }
        isIntentionalDisconnect = true
        isSessionConfigured = false
        receiveLoopID = UUID()

        print("[Gemini][INFO] 사용자가 Live AI 연결 종료 요청 socketState=\(String(describing: webSocket?.state))")
        stopRecording()
        stopPlaybackEngine()

        webSocket?.cancel(with: .goingAway, reason: nil)
        webSocket = nil
        urlSession?.invalidateAndCancel()
        urlSession = nil
    }

    // MARK: - Session configuration

    private func configureSession() {
        guard !isSessionConfigured else { return }

        let instructions = LiveAIModeManager.staticSystemPrompt
        let setupMessage: [String: Any] = [
            "setup": [
                "model": "models/\(model)",
                "responseModalities": ["AUDIO"],
                "speechConfig": [
                    "voiceConfig": [
                        "prebuiltVoiceConfig": [
                            "voiceName": "Aoede"
                        ]
                    ]
                ],
                "systemInstruction": [
                    "parts": [
                        ["text": instructions]
                    ]
                ],
                "inputAudioTranscription": [:] as [String: Any],
                "outputAudioTranscription": [:] as [String: Any]
            ] as [String: Any]
        ]

        print("[Gemini][INFO] 한국어 세션 설정 전송 model=\(model) voice=Aoede instructionLength=\(instructions.count)")
        sendJSON(setupMessage, messageType: "setup")
    }

    // MARK: - Recording

    func startRecording() {
        guard !isRecording else { return }
        guard isSessionConfigured else {
            print("[Gemini][WARN] 세션 설정 완료 전 녹음 시작 요청 무시")
            return
        }

        let session = AVAudioSession.sharedInstance()
        switch session.recordPermission {
        case .undetermined:
            session.requestRecordPermission { [weak self] granted in
                DispatchQueue.main.async {
                    if granted {
                        self?.startRecording()
                    } else {
                        self?.emitError("마이크 권한이 거부되었습니다")
                    }
                }
            }
            return
        case .denied:
            emitError("마이크 권한이 거부되었습니다. iPhone 설정에서 허용하세요")
            return
        case .granted:
            break
        @unknown default:
            emitError("마이크 권한 상태를 확인할 수 없습니다")
            return
        }

        do {
            if let engine = audioEngine, engine.isRunning {
                engine.inputNode.removeTap(onBus: 0)
                engine.stop()
            }
            if audioEngine == nil {
                audioEngine = AVAudioEngine()
            }

            try configureAudioSession()

            guard let engine = audioEngine,
                  let recordTargetFormat else {
                emitError("마이크 오디오 엔진을 만들지 못했습니다")
                return
            }

            let inputNode = engine.inputNode
            let inputFormat = inputNode.outputFormat(forBus: 0)
            recordConverter = AVAudioConverter(from: inputFormat, to: recordTargetFormat)

            print("[Gemini][AUDIO] 녹음 포맷 inputRate=\(inputFormat.sampleRate) inputChannels=\(inputFormat.channelCount) targetRate=16000")
            inputNode.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
                self?.processAudioBuffer(buffer)
            }

            engine.prepare()
            try engine.start()
            isRecording = true
            print("[Gemini][INFO] 마이크 녹음 시작")
        } catch {
            let nsError = error as NSError
            print("[Gemini][ERROR] 녹음 시작 실패 domain=\(nsError.domain) code=\(nsError.code) description=\(nsError.localizedDescription) userInfo=\(nsError.userInfo)")
            emitError("마이크를 시작하지 못했습니다. \(nsError.localizedDescription)")
        }
    }

    func stopRecording() {
        guard isRecording else { return }
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        isRecording = false
        hasAudioBeenSent = false
        print("[Gemini][INFO] 마이크 녹음 중지")
    }

    private func processAudioBuffer(_ buffer: AVAudioPCMBuffer) {
        guard let pcm16Data = convertAudioBufferToPCM16(buffer), !pcm16Data.isEmpty else {
            return
        }

        sendJSON([
            "realtimeInput": [
                "audio": [
                    "data": pcm16Data.base64EncodedString(),
                    "mimeType": "audio/pcm;rate=16000"
                ]
            ]
        ], messageType: "realtimeInput.audio")

        if !hasAudioBeenSent {
            hasAudioBeenSent = true
            print("[Gemini][INFO] 첫 마이크 오디오 전송 bytes=\(pcm16Data.count)")
            DispatchQueue.main.async { [weak self] in
                self?.onFirstAudioSent?()
            }
        }
    }

    private func convertAudioBufferToPCM16(_ input: AVAudioPCMBuffer) -> Data? {
        guard let targetFormat = recordTargetFormat else { return nil }

        let sourceBuffer: AVAudioPCMBuffer
        if input.format.sampleRate == targetFormat.sampleRate && input.format.channelCount == 1 {
            sourceBuffer = input
        } else {
            guard let converted = convert(input, to: targetFormat) else { return nil }
            sourceBuffer = converted
        }

        let frameLength = Int(sourceBuffer.frameLength)
        guard frameLength > 0 else { return nil }

        if let floatData = sourceBuffer.floatChannelData {
            var output = Data(count: frameLength * MemoryLayout<Int16>.size)
            output.withUnsafeMutableBytes { rawBuffer in
                guard let destination = rawBuffer.baseAddress?.assumingMemoryBound(to: Int16.self) else { return }
                for index in 0..<frameLength {
                    let sample = max(-1.0, min(1.0, floatData[0][index]))
                    destination[index] = Int16(sample * 32_767.0).littleEndian
                }
            }
            return output
        }

        if let int16Data = sourceBuffer.int16ChannelData {
            return Data(
                bytes: int16Data[0],
                count: frameLength * MemoryLayout<Int16>.size
            )
        }

        print("[Gemini][WARN] 지원하지 않는 녹음 버퍼 형식 commonFormat=\(sourceBuffer.format.commonFormat.rawValue)")
        return nil
    }

    private func convert(_ input: AVAudioPCMBuffer, to outputFormat: AVAudioFormat) -> AVAudioPCMBuffer? {
        if recordConverter == nil || recordConverter?.inputFormat != input.format {
            recordConverter = AVAudioConverter(from: input.format, to: outputFormat)
        }
        guard let converter = recordConverter else { return nil }

        let ratio = outputFormat.sampleRate / input.format.sampleRate
        let capacity = AVAudioFrameCount(ceil(Double(input.frameLength) * ratio))
        guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else {
            return nil
        }

        var providedInput = false
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, inputStatus in
            if providedInput {
                inputStatus.pointee = .noDataNow
                return nil
            }
            providedInput = true
            inputStatus.pointee = .haveData
            return input
        }

        if let conversionError {
            print("[Gemini][ERROR] 16kHz 변환 실패 description=\(conversionError.localizedDescription)")
            return nil
        }
        guard status != .error else { return nil }
        return output
    }

    // MARK: - Image input

    func sendImageInput(_ image: UIImage) {
        guard isSessionConfigured else {
            print("[Gemini][WARN] 세션 설정 전 이미지 전송 요청 무시")
            return
        }
        guard let imageData = image.jpegData(compressionQuality: 0.6) else {
            print("[Gemini][ERROR] 이미지 JPEG 압축 실패")
            return
        }

        sendJSON([
            "realtimeInput": [
                "video": [
                    "data": imageData.base64EncodedString(),
                    "mimeType": "image/jpeg"
                ]
            ]
        ], messageType: "realtimeInput.video")
        print("[Gemini][INFO] 현재 안경 프레임 전송 imageBytes=\(imageData.count)")
    }

    // MARK: - WebSocket messaging

    private func sendJSON(_ dictionary: [String: Any], messageType: String) {
        guard let data = try? JSONSerialization.data(withJSONObject: dictionary),
              let text = String(data: data, encoding: .utf8) else {
            print("[Gemini][ERROR] JSON 직렬화 실패 type=\(messageType)")
            return
        }

        guard let webSocket, webSocket.state == .running else {
            if !isIntentionalDisconnect {
                print("[Gemini][ERROR] WebSocket이 실행 중이 아니어서 전송 실패 type=\(messageType) state=\(String(describing: self.webSocket?.state))")
            }
            return
        }

        webSocket.send(.string(text)) { [weak self] error in
            guard let self, let error else { return }
            let nsError = error as NSError
            print("[Gemini][ERROR] 전송 실패 type=\(messageType) domain=\(nsError.domain) code=\(nsError.code) description=\(nsError.localizedDescription)")
            guard !self.isIntentionalDisconnect else { return }
            DispatchQueue.main.async {
                self.onError?("Gemini 전송 오류: \(nsError.localizedDescription)")
            }
        }
    }

    private func receiveMessage(loopID: UUID) {
        guard let webSocket else { return }
        webSocket.receive { [weak self] result in
            guard let self else { return }
            guard loopID == self.receiveLoopID else {
                print("[Gemini][INFO] 이전 수신 루프 콜백 무시")
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
                print("[Gemini][\(expected ? "INFO" : "ERROR")] 수신 종료 expected=\(expected) socketState=\(String(describing: state)) domain=\(nsError.domain) code=\(nsError.code) description=\(nsError.localizedDescription)")

                guard !expected else { return }
                DispatchQueue.main.async {
                    self.onError?("Gemini Live 연결이 끊겼습니다. \(nsError.localizedDescription) (\(nsError.domain) \(nsError.code))")
                }
            }
        }
    }

    private func handleMessage(_ message: URLSessionWebSocketTask.Message) {
        let text: String
        switch message {
        case .string(let value):
            text = value
        case .data(let data):
            guard let value = String(data: data, encoding: .utf8) else {
                print("[Gemini][ERROR] 바이너리 응답 UTF-8 변환 실패 bytes=\(data.count)")
                return
            }
            text = value
        @unknown default:
            print("[Gemini][WARN] 알 수 없는 WebSocket 메시지 유형")
            return
        }

        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            print("[Gemini][ERROR] 서버 JSON 파싱 실패 bytes=\(text.utf8.count)")
            return
        }

        DispatchQueue.main.async { [weak self] in
            self?.handleServerMessage(json)
        }
    }

    private func handleServerMessage(_ json: [String: Any]) {
        if json["setupComplete"] != nil {
            isSessionConfigured = true
            print("[Gemini][INFO] 세션 설정 완료 model=\(model)")
            onConnected?()
        }

        if let serverContent = json["serverContent"] as? [String: Any] {
            handleServerContent(serverContent)
        }

        if let toolCall = json["toolCall"] as? [String: Any] {
            let functionCount = (toolCall["functionCalls"] as? [[String: Any]])?.count ?? 0
            print("[Gemini][WARN] 구현되지 않은 도구 호출 수신 functionCount=\(functionCount)")
        }

        if let error = json["error"] as? [String: Any] {
            let code = error["code"].map { String(describing: $0) } ?? "-"
            let message = error["message"] as? String ?? "설명 없는 서버 오류"
            print("[Gemini][ERROR] 서버 오류 code=\(code) message=\(message)")
            onError?("Gemini 서버 오류: \(message) (코드 \(code))")
        }

        if let goAway = json["goAway"] as? [String: Any] {
            let seconds = goAway["timeLeft"] as? String ?? "-"
            print("[Gemini][WARN] 서버 세션 종료 예고 timeLeft=\(seconds)")
        }
    }

    private func handleServerContent(_ content: [String: Any]) {
        if let inputTranscription = content["inputTranscription"] as? [String: Any],
           let text = inputTranscription["text"] as? String,
           !text.isEmpty {
            print("[Gemini][INFO] 사용자 음성 인식 수신 length=\(text.count)")
            onUserTranscript?(text)
        }

        if let outputTranscription = content["outputTranscription"] as? [String: Any],
           let text = outputTranscription["text"] as? String,
           !text.isEmpty {
            print("[Gemini][INFO] AI 출력 자막 수신 length=\(text.count)")
            onTranscriptDelta?(text)
        }

        if let modelTurn = content["modelTurn"] as? [String: Any],
           let parts = modelTurn["parts"] as? [[String: Any]] {
            for part in parts {
                if let inlineData = part["inlineData"] as? [String: Any],
                   let encodedAudio = inlineData["data"] as? String,
                   let audioData = Data(base64Encoded: encodedAudio),
                   !audioData.isEmpty {
                    let mimeType = inlineData["mimeType"] as? String ?? "-"
                    onAudioDelta?(audioData)
                    handleAudioDelta(audioData)
                    if audioChunkCount == 1 {
                        print("[Gemini][AUDIO] 첫 AI 오디오 수신 bytes=\(audioData.count) mimeType=\(mimeType)")
                    }
                }

                if let text = part["text"] as? String, !text.isEmpty {
                    print("[Gemini][INFO] AI 텍스트 조각 수신 length=\(text.count)")
                    onTranscriptDelta?(text)
                }
            }
        }

        if content["interrupted"] as? Bool == true {
            print("[Gemini][INFO] 사용자 발화로 AI 응답 중단")
            stopPlaybackEngine()
            onSpeechStarted?()
        }

        if content["turnComplete"] as? Bool == true {
            finishAudioResponse()
            onSpeechStopped?()
            onTranscriptDone?("")
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
        if !audioBuffer.isEmpty {
            playAudio(audioBuffer)
            audioBuffer.removeAll(keepingCapacity: true)
        }

        if audioChunkCount > 0 {
            print("[Gemini][INFO] AI 오디오 응답 완료 chunks=\(audioChunkCount)")
            onAudioDone?()
        }
        isCollectingAudio = false
        audioChunkCount = 0
        hasStartedPlaying = false
    }

    private func playAudio(_ audioData: Data) {
        guard !audioData.isEmpty,
              let playbackAudioFormat,
              let buffer = createPCMBuffer(from: audioData, format: playbackAudioFormat) else {
            print("[Gemini][WARN] AI 오디오 PCM 변환 실패 bytes=\(audioData.count)")
            return
        }

        if !isPlaybackEngineRunning, !startPlaybackEngine() {
            emitError("Gemini 음성 재생 장치를 시작하지 못했습니다")
            return
        }

        guard let playerNode else { return }
        if !playerNode.isPlaying {
            playerNode.play()
        }
        playerNode.scheduleBuffer(buffer)
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

    private func emitError(_ message: String) {
        print("[Gemini][ERROR] \(message)")
        DispatchQueue.main.async { [weak self] in
            self?.onError?(message)
        }
    }
}

// MARK: - URLSessionWebSocketDelegate

extension GeminiLiveService: URLSessionWebSocketDelegate {
    func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didOpenWithProtocol protocol: String?
    ) {
        print("[Gemini][INFO] WebSocket 열림 protocol=\(`protocol` ?? "-")")
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
        let expected = isIntentionalDisconnect || closeCode == .normalClosure || closeCode == .goingAway
        print("[Gemini][\(expected ? "INFO" : "ERROR")] WebSocket 닫힘 expected=\(expected) code=\(closeCode.rawValue) reason=\(reasonText)")

        guard !expected else { return }
        DispatchQueue.main.async { [weak self] in
            self?.onError?("Gemini Live 연결이 종료되었습니다. 코드 \(closeCode.rawValue), 사유: \(reasonText)")
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error else { return }
        let nsError = error as NSError
        let expected = isIntentionalDisconnect || webSocket?.state == .canceling || webSocket?.state == .completed
        print("[Gemini][\(expected ? "INFO" : "ERROR")] URLSession 작업 종료 expected=\(expected) domain=\(nsError.domain) code=\(nsError.code) description=\(nsError.localizedDescription)")

        guard !expected else { return }
        DispatchQueue.main.async { [weak self] in
            self?.onError?("Gemini Live 네트워크 오류: \(nsError.localizedDescription) (\(nsError.domain) \(nsError.code))")
        }
    }
}
