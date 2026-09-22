/*
 * 회의 통역기 전사 서비스
 *
 * 안경(HFP/LE 오디오 입력)을 우선 라우팅해 iOS 음성 인식으로 한국어 발화를
 * 연속 전사한다. 세그먼트가 확정되면 onSegment로 전달한다.
 * 귓속말 재생 중에는 pause/resume로 인식을 잠시 멈춰 TTS 음성이 전사에 섞이지 않게 한다.
 */

import AVFoundation
import Speech

enum MeetingTranscriptionError: Error {
    case recognizerUnavailable
    case permissionDenied
    case sessionFailed(String)

    var message: String {
        switch self {
        case .recognizerUnavailable:
            return "한국어 음성 인식을 사용할 수 없습니다."
        case .permissionDenied:
            return "마이크와 음성 인식 권한이 필요합니다."
        case .sessionFailed(let detail):
            return "오디오 세션을 시작하지 못했습니다. \(detail)"
        }
    }
}

@MainActor
final class MeetingTranscriptionService: ObservableObject {
    enum ServiceState: Equatable {
        case idle
        case running
        case paused
    }

    @Published private(set) var state: ServiceState = .idle
    @Published private(set) var inputRouteName = "-"

    var onSegment: ((String) -> Void)?
    var onFailure: ((String) -> Void)?

    private let audioEngine = AVAudioEngine()
    private let speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "ko-KR"))
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var restartWorkItem: DispatchWorkItem?
    private var pendingText = ""
    private var recognitionGeneration = 0

    func start() async throws {
        guard let speechRecognizer, speechRecognizer.isAvailable else {
            throw MeetingTranscriptionError.recognizerUnavailable
        }

        let authorized = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status == .authorized)
            }
        }
        guard authorized else {
            throw MeetingTranscriptionError.permissionDenied
        }

        pendingText = ""
        do {
            try configureAudioSession()
        } catch {
            throw MeetingTranscriptionError.sessionFailed(error.localizedDescription)
        }

        state = .running
        startRecognitionLoop()
    }

    func pause() {
        guard state == .running else { return }
        flushPendingSegment()
        state = .paused
        teardownEngine(keepAudioSession: true)
    }

    func resume() {
        guard state == .paused else { return }
        state = .running
        startRecognitionLoop()
    }

    func stop() {
        flushPendingSegment()
        state = .idle
        teardownEngine(keepAudioSession: false)
    }

    private func configureAudioSession() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(
            .playAndRecord,
            mode: .voiceChat,
            options: [.allowBluetooth, .allowBluetoothA2DP, .defaultToSpeaker]
        )
        try session.setActive(true)

        if let bluetoothInput = session.availableInputs?.first(where: {
            $0.portType == .bluetoothHFP || $0.portType == .bluetoothLE
        }) {
            try? session.setPreferredInput(bluetoothInput)
        }

        inputRouteName = session.currentRoute.inputs.first?.portName ?? "-"
        print("[Meeting][AUDIO] 전사 세션 활성 input=\(inputRouteName)")
    }

    private func startRecognitionLoop() {
        guard state == .running, let speechRecognizer else { return }
        teardownTask()

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        if speechRecognizer.supportsOnDeviceRecognition {
            request.requiresOnDeviceRecognition = true
        }
        recognitionRequest = request

        let inputNode = audioEngine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0 else {
            onFailure?("입력 오디오 포맷을 사용할 수 없습니다.")
            state = .idle
            return
        }

        inputNode.removeTap(onBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak request] buffer, _ in
            request?.append(buffer)
        }

        audioEngine.prepare()
        do {
            try audioEngine.start()
        } catch {
            onFailure?("오디오 엔진을 시작하지 못했습니다. \(error.localizedDescription)")
            state = .idle
            return
        }

        recognitionGeneration += 1
        let generation = recognitionGeneration
        recognitionTask = speechRecognizer.recognitionTask(with: request) { [weak self] result, error in
            Task { @MainActor [weak self] in
                self?.handleRecognition(generation: generation, result: result, error: error)
            }
        }
        scheduleRestart()
    }

    private func scheduleRestart() {
        restartWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            Task { @MainActor [weak self] in
                self?.restartCycle()
            }
        }
        restartWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 45, execute: item)
    }

    private func restartCycle() {
        guard state == .running else { return }
        flushPendingSegment()
        startRecognitionLoop()
    }

    private func handleRecognition(
        generation: Int,
        result: SFSpeechRecognitionResult?,
        error: Error?
    ) {
        guard generation == recognitionGeneration, state == .running else { return }

        if let result {
            pendingText = result.bestTranscription.formattedString
            if result.isFinal {
                flushPendingSegment()
                startRecognitionLoop()
            }
            return
        }

        if error != nil {
            restartWorkItem?.cancel()
            flushPendingSegment()
            startRecognitionLoop()
        }
    }

    private func flushPendingSegment() {
        let text = pendingText.trimmingCharacters(in: .whitespacesAndNewlines)
        pendingText = ""
        guard text.count >= 2 else { return }
        onSegment?(text)
    }

    private func teardownTask() {
        recognitionGeneration += 1
        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionRequest?.endAudio()
        recognitionRequest = nil
    }

    private func teardownEngine(keepAudioSession: Bool) {
        restartWorkItem?.cancel()
        restartWorkItem = nil
        teardownTask()
        audioEngine.inputNode.removeTap(onBus: 0)
        audioEngine.stop()
        if !keepAudioSession {
            try? AVAudioSession.sharedInstance().setActive(
                false,
                options: [.notifyOthersOnDeactivation]
            )
        }
    }
}
