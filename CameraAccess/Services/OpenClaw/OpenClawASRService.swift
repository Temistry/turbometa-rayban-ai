/*
 * OpenClaw 한국어 음성 입력 서비스
 * Alibaba Fun-ASR WebSocket으로 16kHz PCM을 전송한다.
 * 사용자 발화 내용과 API Key는 로그에 기록하지 않는다.
 */

import AVFoundation
import Foundation

final class OpenClawASRService: NSObject {
    private var webSocket: URLSessionWebSocketTask?
    private var urlSession: URLSession?

    private var webSocketURL: String {
        switch APIProviderManager.staticAlibabaEndpoint {
        case .beijing:
            return "wss://dashscope.aliyuncs.com/api-ws/v1/inference"
        case .singapore:
            return "wss://dashscope-intl.aliyuncs.com/api-ws/v1/inference"
        }
    }

    private let model = "fun-asr-realtime"
    private let apiKey: String

    private var audioEngine: AVAudioEngine?
    private var audioConverter: AVAudioConverter?
    private let targetSampleRate: Double = 16_000
    private var isRecording = false

    private var taskID: String?
    private var isRunning = false
    private var isIntentionalStop = false

    var onPartialResult: ((String) -> Void)?
    var onFinalResult: ((String) -> Void)?
    var onError: ((String) -> Void)?

    init(apiKey: String) {
        self.apiKey = apiKey
        super.init()
    }

    func start() {
        guard !isRunning else { return }
        guard !apiKey.isEmpty else {
            onError?("음성 인식 API Key가 설정되지 않았습니다")
            return
        }

        isRunning = true
        isIntentionalStop = false
        taskID = UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "")
        connectWebSocket()
    }

    func stop() {
        guard isRunning || webSocket != nil else { return }
        isRunning = false
        isIntentionalStop = true
        stopRecording()

        if webSocket?.state == .running {
            sendStopTask()
        }

        let socket = webSocket
        webSocket = nil
        let session = urlSession
        urlSession = nil

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            socket?.cancel(with: .goingAway, reason: nil)
            session?.invalidateAndCancel()
        }
        print("[ASR][INFO] 음성 인식 종료")
    }

    private func connectWebSocket() {
        guard let url = URL(string: webSocketURL) else {
            onError?("음성 인식 서버 주소가 올바르지 않습니다")
            return
        }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 15

        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData

        let delegateQueue = OperationQueue()
        delegateQueue.name = "com.turbometa.openclaw-asr"
        delegateQueue.maxConcurrentOperationCount = 1
        urlSession = URLSession(configuration: configuration, delegate: self, delegateQueue: delegateQueue)

        let task = urlSession?.webSocketTask(with: request)
        task?.maximumMessageSize = 2 * 1024 * 1024
        webSocket = task
        task?.resume()

        print("[ASR][INFO] Fun-ASR 연결 시작 host=\(url.host ?? "-") endpoint=\(APIProviderManager.staticAlibabaEndpoint.rawValue)")
    }

    private func receiveMessage() {
        guard let webSocket else { return }
        webSocket.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let message):
                self.handleMessage(message)
                self.receiveMessage()

            case .failure(let error):
                let nsError = error as NSError
                let expected = self.isIntentionalStop
                    || self.webSocket?.state == .canceling
                    || self.webSocket?.state == .completed
                print("[ASR][\(expected ? "INFO" : "ERROR")] 수신 종료 expected=\(expected) domain=\(nsError.domain) code=\(nsError.code) description=\(nsError.localizedDescription)")
                if !expected {
                    DispatchQueue.main.async {
                        self.onError?("음성 인식 연결 오류: \(nsError.localizedDescription)")
                    }
                }
            }
        }
    }

    private func sendRunTask() {
        guard let taskID else { return }

        sendJSON([
            "header": [
                "action": "run-task",
                "task_id": taskID,
                "streaming": "duplex"
            ],
            "payload": [
                "task_group": "audio",
                "task": "asr",
                "function": "recognition",
                "model": model,
                "parameters": [
                    "format": "pcm",
                    "sample_rate": 16_000,
                    "vocabulary_id": "",
                    "disfluency_removal_enabled": false
                ] as [String: Any],
                "input": [:] as [String: Any]
            ] as [String: Any]
        ], action: "run-task")
    }

    private func sendStopTask() {
        guard let taskID else { return }
        sendJSON([
            "header": [
                "action": "finish-task",
                "task_id": taskID,
                "streaming": "duplex"
            ],
            "payload": ["input": [:] as [String: Any]]
        ], action: "finish-task")
    }

    private func sendAudioData(_ data: Data) {
        guard let webSocket, webSocket.state == .running else { return }
        webSocket.send(.data(data)) { [weak self] error in
            guard let self, let error else { return }
            let nsError = error as NSError
            print("[ASR][ERROR] 오디오 전송 실패 domain=\(nsError.domain) code=\(nsError.code) description=\(nsError.localizedDescription)")
            if !self.isIntentionalStop {
                DispatchQueue.main.async {
                    self.onError?("음성 데이터 전송 오류: \(nsError.localizedDescription)")
                }
            }
        }
    }

    private func sendJSON(_ dictionary: [String: Any], action: String) {
        guard let data = try? JSONSerialization.data(withJSONObject: dictionary),
              let text = String(data: data, encoding: .utf8),
              let webSocket,
              webSocket.state == .running else {
            print("[ASR][WARN] JSON 전송 준비 실패 action=\(action)")
            return
        }

        webSocket.send(.string(text)) { error in
            if let error {
                let nsError = error as NSError
                print("[ASR][ERROR] JSON 전송 실패 action=\(action) domain=\(nsError.domain) code=\(nsError.code) description=\(nsError.localizedDescription)")
            }
        }
        print("[ASR][INFO] 제어 메시지 전송 action=\(action)")
    }

    private func handleMessage(_ message: URLSessionWebSocketTask.Message) {
        let text: String
        switch message {
        case .string(let string):
            text = string
        case .data(let data):
            text = String(data: data, encoding: .utf8) ?? ""
        @unknown default:
            return
        }

        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let header = json["header"] as? [String: Any] else {
            print("[ASR][ERROR] 서버 메시지 JSON 파싱 실패 bytes=\(text.utf8.count)")
            return
        }

        let event = header["event"] as? String ?? "-"
        switch event {
        case "task-started":
            print("[ASR][INFO] 서버 작업 시작")
            startRecording()

        case "result-generated":
            guard let payload = json["payload"] as? [String: Any],
                  let output = payload["output"] as? [String: Any],
                  let sentence = output["sentence"] as? [String: Any] else { return }

            let recognizedText = sentence["text"] as? String ?? ""
            let endTime = sentence["end_time"] as? Int ?? 0
            guard !recognizedText.isEmpty else { return }

            // 인식된 발화는 개인정보일 수 있으므로 내용은 로그에 남기지 않는다.
            print("[ASR][INFO] 인식 결과 수신 final=\(endTime > 0) length=\(recognizedText.count)")
            DispatchQueue.main.async {
                if endTime > 0 {
                    self.onFinalResult?(recognizedText)
                } else {
                    self.onPartialResult?(recognizedText)
                }
            }

        case "task-finished":
            print("[ASR][INFO] 서버 작업 종료")

        case "task-failed":
            let code = header["error_code"].map { String(describing: $0) } ?? "-"
            let message = header["error_message"] as? String ?? "설명 없는 서버 오류"
            print("[ASR][ERROR] 서버 작업 실패 code=\(code) message=\(message)")
            DispatchQueue.main.async {
                self.onError?("음성 인식 서버 오류: \(message) (코드 \(code))")
            }

        default:
            print("[ASR][INFO] 서버 이벤트 event=\(event)")
        }
    }

    private func startRecording() {
        guard !isRecording else { return }

        do {
            let audioSession = AVAudioSession.sharedInstance()
            try audioSession.setCategory(
                .playAndRecord,
                mode: .voiceChat,
                options: [.allowBluetooth, .defaultToSpeaker]
            )
            try audioSession.setActive(true)

            let engine = AVAudioEngine()
            audioEngine = engine
            let inputNode = engine.inputNode
            let inputFormat = inputNode.outputFormat(forBus: 0)

            let inputs = audioSession.currentRoute.inputs
                .map { "\($0.portType.rawValue):\($0.portName)" }
                .joined(separator: ",")
            print("[ASR][AUDIO] 녹음 시작 input=[\(inputs)] sampleRate=\(inputFormat.sampleRate) channels=\(inputFormat.channelCount) targetSampleRate=16000")

            inputNode.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
                self?.processAudioBuffer(buffer)
            }

            engine.prepare()
            try engine.start()
            isRecording = true
        } catch {
            let nsError = error as NSError
            print("[ASR][ERROR] 녹음 시작 실패 domain=\(nsError.domain) code=\(nsError.code) description=\(nsError.localizedDescription) userInfo=\(nsError.userInfo)")
            DispatchQueue.main.async {
                self.onError?("마이크 시작 오류: \(nsError.localizedDescription)")
            }
        }
    }

    private func stopRecording() {
        guard isRecording else { return }
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        audioEngine = nil
        audioConverter = nil
        isRecording = false
        print("[ASR][INFO] 녹음 중지")
    }

    private func processAudioBuffer(_ buffer: AVAudioPCMBuffer) {
        let outputBuffer: AVAudioPCMBuffer
        if buffer.format.sampleRate != targetSampleRate || buffer.format.channelCount != 1 {
            guard let resampled = resample(buffer) else { return }
            outputBuffer = resampled
        } else {
            outputBuffer = buffer
        }

        guard let floatData = outputBuffer.floatChannelData else { return }
        let frameLength = Int(outputBuffer.frameLength)
        var pcmData = Data(count: frameLength * MemoryLayout<Int16>.size)
        pcmData.withUnsafeMutableBytes { rawBuffer in
            guard let pointer = rawBuffer.baseAddress?.assumingMemoryBound(to: Int16.self) else { return }
            for index in 0..<frameLength {
                let sample = max(-1.0, min(1.0, floatData[0][index]))
                pointer[index] = Int16(sample * 32_767.0).littleEndian
            }
        }
        sendAudioData(pcmData)
    }

    private func resample(_ input: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let outputFormat = AVAudioFormat(
            standardFormatWithSampleRate: targetSampleRate,
            channels: 1
        ) else { return nil }

        if audioConverter == nil || audioConverter?.inputFormat != input.format {
            audioConverter = AVAudioConverter(from: input.format, to: outputFormat)
        }
        guard let converter = audioConverter else { return nil }

        let ratio = targetSampleRate / input.format.sampleRate
        let outputFrameCount = AVAudioFrameCount(Double(input.frameLength) * ratio)
        guard let output = AVAudioPCMBuffer(
            pcmFormat: outputFormat,
            frameCapacity: outputFrameCount
        ) else { return nil }

        var providedInput = false
        var conversionError: NSError?
        converter.convert(to: output, error: &conversionError) { _, status in
            if providedInput {
                status.pointee = .noDataNow
                return nil
            }
            providedInput = true
            status.pointee = .haveData
            return input
        }

        if let conversionError {
            print("[ASR][ERROR] 16kHz 리샘플링 실패 description=\(conversionError.localizedDescription)")
            return nil
        }
        return output
    }
}

extension OpenClawASRService: URLSessionWebSocketDelegate {
    func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didOpenWithProtocol protocol: String?
    ) {
        print("[ASR][INFO] WebSocket 열림 protocol=\(`protocol` ?? "-")")
        receiveMessage()
        sendRunTask()
    }

    func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
        reason: Data?
    ) {
        let reasonText = reason.flatMap { String(data: $0, encoding: .utf8) } ?? "-"
        let expected = isIntentionalStop || closeCode == .goingAway || closeCode == .normalClosure
        print("[ASR][\(expected ? "INFO" : "ERROR")] WebSocket 닫힘 expected=\(expected) code=\(closeCode.rawValue) reason=\(reasonText)")
    }
}
