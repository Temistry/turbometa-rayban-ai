/*
 * Alibaba Qwen 실시간 번역 서비스
 *
 * qwen3-livetranslate-flash-realtime WebSocket에 16kHz PCM 음성과 선택적
 * 안경 프레임을 전송하고, 번역 텍스트와 한국어 음성을 재생한다.
 * 사용자 발화와 번역 원문은 진단 로그에 남기지 않는다.
 */

import AVFoundation
import Foundation
import UIKit

final class LiveTranslateService: NSObject {
    private var webSocket: URLSessionWebSocketTask?
    private var urlSession: URLSession?

    private let apiKey: String
    private let model = "qwen3-livetranslate-flash-realtime"
    private var baseURL: String {
        APIProviderManager.staticAlibabaEndpoint.websocketURL
    }

    private var audioEngine: AVAudioEngine?
    private var audioConverter: AVAudioConverter?
    private let targetSampleRate: Double = 16_000

    private var playbackEngine: AVAudioEngine?
    private var playerNode: AVAudioPlayerNode?
    private let playbackFormat = AVAudioFormat(standardFormatWithSampleRate: 24_000, channels: 1)
    private var isPlaybackEngineRunning = false
    private var audioBuffer = Data()
    private var isCollectingAudio = false
    private var audioChunkCount = 0
    private let minimumChunksBeforePlayback = 2
    private var hasStartedPlaying = false

    private var sourceLanguage: TranslateLanguage = .en
    private var targetLanguage: TranslateLanguage = .ko
    private var voice: TranslateVoice = .cherry
    private var audioOutputEnabled = true

    var onConnected: (() -> Void)?
    var onTranslationText: ((String) -> Void)?
    var onTranslationDelta: ((String) -> Void)?
    var onAudioDelta: ((Data) -> Void)?
    var onAudioDone: (() -> Void)?
    var onError: ((String) -> Void)?

    private var isRecording = false
    private var eventIDCounter = 0
    private var audioSendCount = 0
    private var hasEstablishedSession = false
    private var isIntentionalDisconnect = false
    private var receiveLoopID = UUID()

    private var lastImageSendTime: Date?
    private let imageInterval: TimeInterval = 0.5
    private let maximumImageBytes = 500 * 1_024

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
            print("[Translate][ERROR] 24kHz mono 재생 포맷 생성 실패")
            return
        }

        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: playbackFormat)
        engine.prepare()

        playbackEngine = engine
        playerNode = node
        isPlaybackEngineRunning = false
        print("[Translate][AUDIO] 재생 엔진 초기화 sampleRate=24000 channels=1")
    }

    private func configureAudioSession(usePhoneMic: Bool? = nil) throws {
        let session = AVAudioSession.sharedInstance()
        var options: AVAudioSession.CategoryOptions = [.defaultToSpeaker]

        if usePhoneMic != true {
            options.insert(.allowBluetooth)
            options.insert(.allowBluetoothA2DP)
        }

        try session.setCategory(.playAndRecord, mode: .voiceChat, options: options)
        try session.setActive(true, options: [.notifyOthersOnDeactivation])

        if usePhoneMic == true,
           let builtInMic = session.availableInputs?.first(where: { $0.portType == .builtInMic }) {
            try session.setPreferredInput(builtInMic)
        } else if usePhoneMic == false,
                  let bluetoothInput = session.availableInputs?.first(where: {
                      $0.portType == .bluetoothHFP || $0.portType == .bluetoothLE
                  }) {
            try session.setPreferredInput(bluetoothInput)
        }

        let inputs = session.currentRoute.inputs
            .map { "\($0.portType.rawValue):\($0.portName)" }
            .joined(separator: ",")
        let outputs = session.currentRoute.outputs
            .map { "\($0.portType.rawValue):\($0.portName)" }
            .joined(separator: ",")
        print("[Translate][AUDIO] 세션 활성 input=[\(inputs)] output=[\(outputs)] sampleRate=\(session.sampleRate) phoneMic=\(String(describing: usePhoneMic))")
    }

    @discardableResult
    private func startPlaybackEngine() -> Bool {
        if isPlaybackEngineRunning { return true }
        if playbackEngine == nil || playerNode == nil {
            setupPlaybackEngine()
        }

        guard let playbackEngine, let playerNode else {
            print("[Translate][ERROR] 재생 엔진 또는 player node 없음")
            return false
        }

        do {
            try configureAudioSession()
            try playbackEngine.start()
            playerNode.play()
            isPlaybackEngineRunning = true
            print("[Translate][AUDIO] 재생 엔진 시작 성공")
            return true
        } catch {
            let nsError = error as NSError
            print("[Translate][ERROR] 재생 엔진 시작 실패 domain=\(nsError.domain) code=\(nsError.code) description=\(nsError.localizedDescription) userInfo=\(nsError.userInfo)")
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
        print("[Translate][AUDIO] 재생 엔진 중지 및 큐 정리")
    }

    // MARK: - Connection

    func connect() {
        guard !apiKey.isEmpty else {
            emitError("Alibaba 번역 API Key가 설정되지 않았습니다")
            return
        }

        if let webSocket, webSocket.state == .running {
            print("[Translate][WARN] 이미 WebSocket이 실행 중이므로 연결 요청 무시")
            return
        }

        isIntentionalDisconnect = false
        hasEstablishedSession = false
        receiveLoopID = UUID()

        let urlString = "\(baseURL)?model=\(model)"
        guard let url = URL(string: urlString) else {
            emitError("실시간 번역 서버 주소가 올바르지 않습니다")
            print("[Translate][ERROR] 잘못된 WebSocket URL baseURL=\(baseURL)")
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
        delegateQueue.name = "com.turbometa.live-translate"
        delegateQueue.maxConcurrentOperationCount = 1
        urlSession = URLSession(configuration: configuration, delegate: self, delegateQueue: delegateQueue)

        let task = urlSession?.webSocketTask(with: request)
        task?.maximumMessageSize = 16 * 1_024 * 1_024
        webSocket = task
        task?.resume()

        print("[Translate][INFO] WebSocket 연결 시작 host=\(url.host ?? "-") model=\(model) endpoint=\(APIProviderManager.staticAlibabaEndpoint.rawValue)")
        receiveMessage(loopID: receiveLoopID)
    }

    func disconnect() {
        guard !isIntentionalDisconnect else { return }
        isIntentionalDisconnect = true
        hasEstablishedSession = false
        receiveLoopID = UUID()

        print("[Translate][INFO] 사용자가 번역 연결 종료 요청 socketState=\(String(describing: webSocket?.state))")
        stopRecording()
        stopPlaybackEngine()

        webSocket?.cancel(with: .goingAway, reason: nil)
        webSocket = nil
        urlSession?.invalidateAndCancel()
        urlSession = nil
    }

    // MARK: - Configuration

    func updateSettings(
        sourceLanguage: TranslateLanguage,
        targetLanguage: TranslateLanguage,
        voice: TranslateVoice,
        audioEnabled: Bool
    ) {
        self.sourceLanguage = sourceLanguage
        self.targetLanguage = targetLanguage
        self.voice = voice.supports(language: targetLanguage) ? voice : .cherry
        self.audioOutputEnabled = audioEnabled

        if webSocket?.state == .running {
            configureSession()
        }
    }

    private func configureSession() {
        var modalities = ["text"]
        if audioOutputEnabled {
            modalities.append("audio")
        }

        let event: [String: Any] = [
            "event_id": generateEventID(),
            "type": TranslateClientEvent.sessionUpdate.rawValue,
            "session": [
                "modalities": modalities,
                "voice": voice.rawValue,
                "input_audio_format": "pcm16",
                "output_audio_format": "pcm24",
                "input_audio_transcription": [
                    "language": sourceLanguage.rawValue
                ],
                "translation": [
                    "language": targetLanguage.rawValue
                ],
                "turn_detection": [
                    "type": "server_vad",
                    "threshold": 0.5,
                    "prefix_padding_ms": 300,
                    "silence_duration_ms": 500
                ]
            ]
        ]

        sendEvent(event, eventType: TranslateClientEvent.sessionUpdate.rawValue)
        print("[Translate][INFO] 세션 설정 전송 source=\(sourceLanguage.rawValue) target=\(targetLanguage.rawValue) voice=\(voice.rawValue) audio=\(audioOutputEnabled)")
    }

    // MARK: - Recording

    func startRecording(usePhoneMic: Bool = false) {
        guard !isRecording else { return }
        guard hasEstablishedSession else {
            print("[Translate][WARN] 세션 연결 전 녹음 시작 요청 무시")
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

            try configureAudioSession(usePhoneMic: usePhoneMic)

            guard let engine = audioEngine else {
                emitError("마이크 오디오 엔진을 만들지 못했습니다")
                return
            }

            let inputNode = engine.inputNode
            let inputFormat = inputNode.outputFormat(forBus: 0)
            print("[Translate][AUDIO] 녹음 포맷 inputRate=\(inputFormat.sampleRate) channels=\(inputFormat.channelCount) targetRate=16000 microphone=\(usePhoneMic ? "iphone" : "glasses")")

            inputNode.installTap(onBus: 0, bufferSize: 4_096, format: inputFormat) { [weak self] buffer, _ in
                self?.processAudioBuffer(buffer)
            }

            engine.prepare()
            try engine.start()
            isRecording = true
            audioSendCount = 0
            print("[Translate][INFO] 녹음 시작")
        } catch {
            let nsError = error as NSError
            print("[Translate][ERROR] 녹음 시작 실패 domain=\(nsError.domain) code=\(nsError.code) description=\(nsError.localizedDescription) userInfo=\(nsError.userInfo)")
            emitError("마이크를 시작하지 못했습니다. \(nsError.localizedDescription)")
        }
    }

    func stopRecording() {
        guard isRecording else { return }
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        audioConverter = nil
        isRecording = false
        print("[Translate][INFO] 녹음 중지 audioChunksSent=\(audioSendCount)")
    }

    private func processAudioBuffer(_ buffer: AVAudioPCMBuffer) {
        let sourceBuffer: AVAudioPCMBuffer
        if buffer.format.sampleRate != targetSampleRate || buffer.format.channelCount != 1 {
            guard let converted = resampleBuffer(buffer) else { return }
            sourceBuffer = converted
        } else {
            sourceBuffer = buffer
        }
        sendBufferAsPCM16(sourceBuffer)
    }

    private func resampleBuffer(_ inputBuffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let outputFormat = AVAudioFormat(
            standardFormatWithSampleRate: targetSampleRate,
            channels: 1
        ) else { return nil }

        if audioConverter == nil || audioConverter?.inputFormat != inputBuffer.format {
            audioConverter = AVAudioConverter(from: inputBuffer.format, to: outputFormat)
        }
        guard let converter = audioConverter else {
            print("[Translate][ERROR] 16kHz 오디오 변환기 생성 실패")
            return nil
        }

        let ratio = targetSampleRate / inputBuffer.format.sampleRate
        let outputCapacity = AVAudioFrameCount(ceil(Double(inputBuffer.frameLength) * ratio))
        guard let outputBuffer = AVAudioPCMBuffer(
            pcmFormat: outputFormat,
            frameCapacity: max(1, outputCapacity)
        ) else { return nil }

        var providedInput = false
        var conversionError: NSError?
        let status = converter.convert(to: outputBuffer, error: &conversionError) { _, inputStatus in
            if providedInput {
                inputStatus.pointee = .noDataNow
                return nil
            }
            providedInput = true
            inputStatus.pointee = .haveData
            return inputBuffer
        }

        if let conversionError {
            print("[Translate][ERROR] 16kHz 리샘플링 실패 description=\(conversionError.localizedDescription)")
            return nil
        }
        guard status != .error else { return nil }
        return outputBuffer
    }

    private func sendBufferAsPCM16(_ buffer: AVAudioPCMBuffer) {
        guard let floatChannelData = buffer.floatChannelData else {
            print("[Translate][WARN] 녹음 버퍼 floatChannelData 없음")
            return
        }

        let frameLength = Int(buffer.frameLength)
        guard frameLength > 0 else { return }

        let channel = floatChannelData[0]
        var int16Data = [Int16](repeating: 0, count: frameLength)
        for index in 0..<frameLength {
            let sample = max(-1.0, min(1.0, channel[index]))
            int16Data[index] = Int16(sample * 32_767.0).littleEndian
        }

        let data = Data(
            bytes: int16Data,
            count: frameLength * MemoryLayout<Int16>.size
        )
        sendAudioAppend(data.base64EncodedString(), rawBytes: data.count)
    }

    // MARK: - Image input

    func sendImageFrame(_ image: UIImage) {
        guard hasEstablishedSession else { return }

        let now = Date()
        if let lastImageSendTime,
           now.timeIntervalSince(lastImageSendTime) < imageInterval {
            return
        }
        lastImageSendTime = now

        guard let imageData = compressedImageData(image) else {
            print("[Translate][WARN] 이미지가 \(maximumImageBytes)바이트 제한을 초과해 전송 생략")
            return
        }

        sendEvent([
            "event_id": generateEventID(),
            "type": TranslateClientEvent.inputImageBufferAppend.rawValue,
            "image": imageData.base64EncodedString()
        ], eventType: TranslateClientEvent.inputImageBufferAppend.rawValue)
        print("[Translate][INFO] 현재 안경 프레임 전송 imageBytes=\(imageData.count)")
    }

    private func compressedImageData(_ image: UIImage) -> Data? {
        for quality in [0.60, 0.45, 0.30, 0.20] {
            if let data = image.jpegData(compressionQuality: quality),
               data.count <= maximumImageBytes {
                return data
            }
        }
        return nil
    }

    // MARK: - WebSocket messaging

    private func sendEvent(_ event: [String: Any], eventType: String) {
        guard let jsonData = try? JSONSerialization.data(withJSONObject: event),
              let jsonString = String(data: jsonData, encoding: .utf8) else {
            print("[Translate][ERROR] 이벤트 직렬화 실패 type=\(eventType)")
            return
        }

        guard let webSocket, webSocket.state == .running else {
            if !isIntentionalDisconnect {
                print("[Translate][ERROR] WebSocket이 실행 중이 아니어서 전송 실패 type=\(eventType) state=\(String(describing: self.webSocket?.state))")
            }
            return
        }

        webSocket.send(.string(jsonString)) { [weak self] error in
            guard let self, let error else { return }
            let nsError = error as NSError
            print("[Translate][ERROR] 이벤트 전송 실패 type=\(eventType) domain=\(nsError.domain) code=\(nsError.code) description=\(nsError.localizedDescription)")
            guard !self.isIntentionalDisconnect else { return }
            DispatchQueue.main.async {
                self.onError?("번역 데이터 전송 오류: \(nsError.localizedDescription)")
            }
        }
    }

    private func sendAudioAppend(_ encodedAudio: String, rawBytes: Int) {
        audioSendCount += 1
        if audioSendCount == 1 || audioSendCount.isMultiple(of: 50) {
            print("[Translate][AUDIO] 음성 청크 전송 count=\(audioSendCount) rawBytes=\(rawBytes)")
        }

        sendEvent([
            "event_id": generateEventID(),
            "type": TranslateClientEvent.inputAudioBufferAppend.rawValue,
            "audio": encodedAudio
        ], eventType: TranslateClientEvent.inputAudioBufferAppend.rawValue)
    }

    private func receiveMessage(loopID: UUID) {
        guard let webSocket else { return }
        webSocket.receive { [weak self] result in
            guard let self else { return }
            guard loopID == self.receiveLoopID else {
                print("[Translate][INFO] 이전 수신 루프 콜백 무시")
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
                print("[Translate][\(expected ? "INFO" : "ERROR")] 수신 종료 expected=\(expected) socketState=\(String(describing: state)) domain=\(nsError.domain) code=\(nsError.code) description=\(nsError.localizedDescription)")

                guard !expected else { return }
                DispatchQueue.main.async {
                    self.onError?("실시간 번역 연결이 끊겼습니다. \(nsError.localizedDescription) (\(nsError.domain) \(nsError.code))")
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
                print("[Translate][ERROR] 바이너리 응답 UTF-8 변환 실패 bytes=\(data.count)")
                return
            }
            text = value
        @unknown default:
            print("[Translate][WARN] 알 수 없는 WebSocket 메시지 유형")
            return
        }

        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String else {
            print("[Translate][ERROR] 서버 이벤트 JSON 파싱 실패 bytes=\(text.utf8.count)")
            return
        }

        DispatchQueue.main.async { [weak self] in
            self?.handleServerEvent(type: type, json: json)
        }
    }

    private func handleServerEvent(type: String, json: [String: Any]) {
        switch type {
        case TranslateServerEvent.sessionCreated.rawValue,
             TranslateServerEvent.sessionUpdated.rawValue:
            let firstConnection = !hasEstablishedSession
            hasEstablishedSession = true
            print("[Translate][INFO] 번역 세션 설정 완료 type=\(type) first=\(firstConnection)")
            if firstConnection {
                onConnected?()
            }

        case TranslateServerEvent.responseAudioTranscriptText.rawValue:
            if let delta = json["delta"] as? String, !delta.isEmpty {
                print("[Translate][INFO] 번역 자막 조각 수신 length=\(delta.count)")
                onTranslationDelta?(delta)
            }

        case TranslateServerEvent.responseAudioTranscriptDone.rawValue,
             TranslateServerEvent.responseTextDone.rawValue:
            if let text = json["text"] as? String, !text.isEmpty {
                print("[Translate][INFO] 번역 문장 완료 type=\(type) length=\(text.count)")
                onTranslationText?(text)
            }

        case TranslateServerEvent.responseAudioDelta.rawValue:
            if let encodedAudio = json["delta"] as? String,
               let audioData = Data(base64Encoded: encodedAudio),
               !audioData.isEmpty {
                onAudioDelta?(audioData)
                handleAudioChunk(audioData)
            }

        case TranslateServerEvent.responseAudioDone.rawValue:
            finishAudioResponse()

        case TranslateServerEvent.responseCreated.rawValue,
             TranslateServerEvent.responseOutputItemAdded.rawValue,
             TranslateServerEvent.responseContentPartAdded.rawValue,
             TranslateServerEvent.responseContentPartDone.rawValue,
             TranslateServerEvent.responseOutputItemDone.rawValue,
             TranslateServerEvent.responseDone.rawValue:
            print("[Translate][INFO] 서버 이벤트 type=\(type)")

        case TranslateServerEvent.error.rawValue:
            let errorDictionary = json["error"] as? [String: Any]
            let code = errorDictionary?["code"].map(String.init(describing:)) ?? "-"
            let message = errorDictionary?["message"] as? String ?? "설명 없는 서버 오류"
            print("[Translate][ERROR] 서버 오류 code=\(code) message=\(message)")
            onError?("실시간 번역 서버 오류: \(message) (코드 \(code))")

        default:
            print("[Translate][INFO] 처리하지 않는 서버 이벤트 type=\(type)")
        }
    }

    // MARK: - Audio playback

    private func handleAudioChunk(_ audioData: Data) {
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

        print("[Translate][INFO] 번역 음성 응답 완료 chunks=\(audioChunkCount)")
        isCollectingAudio = false
        audioChunkCount = 0
        hasStartedPlaying = false
        onAudioDone?()
    }

    private func playAudio(_ audioData: Data) {
        guard !audioData.isEmpty,
              let playbackFormat,
              let pcmBuffer = createPCMBuffer(from: audioData, format: playbackFormat) else {
            print("[Translate][WARN] 번역 음성 PCM 변환 실패 bytes=\(audioData.count)")
            return
        }

        if !isPlaybackEngineRunning, !startPlaybackEngine() {
            emitError("번역 음성 재생 장치를 시작하지 못했습니다")
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
        return "translate_\(eventIDCounter)_\(UUID().uuidString.prefix(8))"
    }

    private func emitError(_ message: String) {
        print("[Translate][ERROR] \(message)")
        DispatchQueue.main.async { [weak self] in
            self?.onError?(message)
        }
    }
}

// MARK: - URLSessionWebSocketDelegate

extension LiveTranslateService: URLSessionWebSocketDelegate {
    func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didOpenWithProtocol protocol: String?
    ) {
        print("[Translate][INFO] WebSocket 열림 protocol=\(`protocol` ?? "-")")
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
        print("[Translate][\(expected ? "INFO" : "ERROR")] WebSocket 닫힘 expected=\(expected) code=\(closeCode.rawValue) reason=\(reasonText)")

        guard !expected else { return }
        DispatchQueue.main.async { [weak self] in
            self?.onError?("실시간 번역 연결이 종료되었습니다. 코드 \(closeCode.rawValue), 사유: \(reasonText)")
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error else { return }
        let nsError = error as NSError
        let expected = isIntentionalDisconnect || webSocket?.state == .canceling || webSocket?.state == .completed
        print("[Translate][\(expected ? "INFO" : "ERROR")] URLSession 작업 종료 expected=\(expected) domain=\(nsError.domain) code=\(nsError.code) description=\(nsError.localizedDescription)")

        guard !expected else { return }
        DispatchQueue.main.async { [weak self] in
            self?.onError?("실시간 번역 네트워크 오류: \(nsError.localizedDescription) (\(nsError.domain) \(nsError.code))")
        }
    }
}
