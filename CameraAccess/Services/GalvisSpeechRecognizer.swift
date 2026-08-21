import AVFoundation
import Speech

@MainActor
final class GalvisSpeechRecognizer: NSObject, ObservableObject {
    enum RecognitionError: LocalizedError {
        case unavailable
        case permissionDenied
        case emptyTranscript

        var errorDescription: String? {
            switch self {
            case .unavailable:
                return "한국어 음성 인식을 사용할 수 없습니다."
            case .permissionDenied:
                return "마이크와 음성 인식 권한이 필요합니다."
            case .emptyTranscript:
                return "음성을 인식하지 못했습니다. 다시 말씀해 주세요."
            }
        }
    }

    @Published private(set) var transcript = ""
    @Published private(set) var isListening = false

    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "ko-KR"))
    private let audioEngine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var continuation: CheckedContinuation<String, any Error>?
    private var silenceTask: Task<Void, Never>?
    private var generation = 0

    static func requestAuthorization() async -> Bool {
        let speechStatus: SFSpeechRecognizerAuthorizationStatus = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
        }
        guard speechStatus == .authorized else { return false }
        return await withCheckedContinuation { continuation in
            AVAudioSession.sharedInstance().requestRecordPermission {
                continuation.resume(returning: $0)
            }
        }
    }

    func listen() async throws -> String {
        guard let recognizer, recognizer.isAvailable else {
            throw RecognitionError.unavailable
        }
        guard SFSpeechRecognizer.authorizationStatus() == .authorized,
              AVAudioSession.sharedInstance().recordPermission == .granted else {
            throw RecognitionError.permissionDenied
        }

        stop(resumingWith: nil)
        transcript = ""
        generation += 1
        let currentGeneration = generation

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.contextualStrings = ["갈비스", "오픈클로", "갈비스 종료", "대화 종료", "그만 들어", "마이크 꺼"]
        if recognizer.supportsOnDeviceRecognition {
            request.requiresOnDeviceRecognition = true
        }
        self.request = request

        let inputNode = audioEngine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        inputNode.removeTap(onBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1_024, format: format) { [weak request] buffer, _ in
            request?.append(buffer)
        }

        audioEngine.prepare()
        try audioEngine.start()
        isListening = true
        print("[Galvis][STT] 음성 인식 시작 onDevice=\(request.requiresOnDeviceRecognition)")

        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            self.task = recognizer.recognitionTask(with: request) { [weak self] result, error in
                Task { @MainActor in
                    guard let self, self.generation == currentGeneration else { return }
                    if let result {
                        let text = result.bestTranscription.formattedString
                        self.transcript = text
                        self.scheduleSilenceFinish(generation: currentGeneration)
                        if result.isFinal {
                            self.finish(text: text, error: nil)
                        }
                    } else if let error {
                        self.finish(text: nil, error: error)
                    }
                }
            }
        }
    }

    func cancel() {
        stop(resumingWith: CancellationError())
    }

    func reset() {
        stop(resumingWith: CancellationError())
        audioEngine.reset()
        transcript = ""
        print("[Galvis][STT] 음성 인식 엔진 재설정")
    }

    private func scheduleSilenceFinish(generation: Int) {
        silenceTask?.cancel()
        silenceTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self, self.generation == generation else { return }
                self.finish(text: self.transcript, error: nil)
            }
        }
    }

    private func finish(text: String?, error: Error?) {
        let normalized = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if let error {
            stop(resumingWith: error)
        } else if normalized.isEmpty {
            stop(resumingWith: RecognitionError.emptyTranscript)
        } else {
            stop(resumingWith: normalized)
        }
    }

    private func stop(resumingWith result: Any?) {
        silenceTask?.cancel()
        silenceTask = nil
        task?.cancel()
        task = nil
        request?.endAudio()
        request = nil

        if audioEngine.isRunning {
            audioEngine.stop()
        }
        audioEngine.inputNode.removeTap(onBus: 0)
        isListening = false

        guard let continuation else { return }
        self.continuation = nil
        if let text = result as? String {
            continuation.resume(returning: text)
        } else if let error = result as? Error {
            continuation.resume(throwing: error)
        } else {
            continuation.resume(throwing: CancellationError())
        }
        print("[Galvis][STT] 음성 인식 종료 textLength=\(transcript.count)")
    }
}
