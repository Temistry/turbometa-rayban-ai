/*
 * 회의 통역기 전사 서비스
 *
 * 안경(HFP/LE 오디오 입력)을 우선 라우팅해 iOS 음성 인식으로 한국어 발화를
 * 연속 전사한다. 회의 귓속말은 동일한 playAndRecord 세션을 유지한다.
 *
 * 품질과 반응성:
 * - 기본은 서버 음성 인식(전문용어 정확도) + 문장부호 추가.
 * - 모든 중간 결과를 즉시 표시하고, 안정된 스냅샷만 AI 판단으로 보낸다.
 * - 반복 오류는 지연 재시도하고, 임시 온디바이스 전환 후 서버를 다시 시도한다.
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
    var onPartial: ((String) -> Void)?
    var onStable: ((String) -> Void)?
    var onFailure: ((String) -> Void)?
    /// 시각 보조가 뽑은 화면 용어. 인식 작업 시작 시 contextualStrings로 주입된다.
    var contextualTerms: [String] = []
    /// 설정되면 입력 오디오를 이 파일에 원본으로 기록한다.
    var recordingDestination: URL? {
        didSet { audioFileBox.clear() }
    }

    private let audioEngine = AVAudioEngine()
    private let speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "ko-KR"))
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var restartWorkItem: DispatchWorkItem?
    private var tickerWorkItem: DispatchWorkItem?
    private var pendingText = ""
    private var recognitionGeneration = 0
    private var consecutiveTaskErrors = 0
    private var prefersOnDevice = false
    private var hasInputTap = false
    private var lastPartialAt = Date.distantPast
    private var lastStableText = ""
    private var lastStableAt = Date.distantPast
    private var onDeviceUntil = Date.distantPast
    private let audioFileBox = MeetingAudioFileBox()

    /// 부분 결과 증분 발행 주기(초).
    static let segmentTickerInterval: TimeInterval = 0.5

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
        let microphoneAuthorized = await withCheckedContinuation { continuation in
            AVAudioSession.sharedInstance().requestRecordPermission { granted in
                continuation.resume(returning: granted)
            }
        }
        guard microphoneAuthorized else { throw MeetingTranscriptionError.permissionDenied }
        try Task.checkCancellation()

        pendingText = ""
        prefersOnDevice = false
        consecutiveTaskErrors = 0
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
        flushRemainder()
        state = .paused
        teardownEngine(keepAudioSession: true)
    }

    func resume() {
        guard state == .paused else { return }

        // TTS 재생이 세션을 .playback으로 바꿔 두므로 입력 세션을 다시 구성한다.
        do {
            try configureAudioSession()
        } catch {
            onFailure?("귓속말 재생 후 전사 세션을 복구하지 못했습니다. \(error.localizedDescription)")
            state = .idle
            return
        }

        state = .running
        startRecognitionLoop()
    }

    func stop() {
        flushRemainder()
        state = .idle
        teardownEngine(keepAudioSession: false)
        audioFileBox.clear()
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
        DeveloperConsole.shared.log(.info, category: "MeetingAudio", "input=\(inputRouteName) outputs=\(session.currentRoute.outputs.map { $0.portType.rawValue }.joined(separator: ",")) rate=\(session.sampleRate)")
    }

    private func startRecognitionLoop() {
        guard state == .running, let speechRecognizer else { return }
        if prefersOnDevice, Date() >= onDeviceUntil {
            prefersOnDevice = false
            DeveloperConsole.shared.log(.info, category: "MeetingSpeech", "retry server recognition")
        }
        audioEngine.stop()
        if hasInputTap {
            audioEngine.inputNode.removeTap(onBus: 0)
            hasInputTap = false
        }
        teardownTask()
        pendingText = ""
        lastStableText = ""
        lastStableAt = Date()

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.addsPunctuation = true
        if !contextualTerms.isEmpty {
            request.contextualStrings = Array(
                contextualTerms
                    .filter { !$0.isEmpty && $0.count <= 60 }
                    .prefix(40)
            )
        }
        if prefersOnDevice {
            request.requiresOnDeviceRecognition = true
        }
        recognitionRequest = request

        let inputNode = audioEngine.inputNode
        if !inputNode.isVoiceProcessingEnabled {
            do { try inputNode.setVoiceProcessingEnabled(true) }
            catch {
                DeveloperConsole.shared.log(.warning, category: "MeetingAudio", "voiceProcessing unavailable code=\((error as NSError).code)")
            }
        }
        let inputFormat = inputNode.outputFormat(forBus: 0)
        DeveloperConsole.shared.log(.info, category: "MeetingSpeech", "start onDevice=\(prefersOnDevice) rate=\(inputFormat.sampleRate) channels=\(inputFormat.channelCount) echoProcessing=\(inputNode.isVoiceProcessingEnabled)")
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            onFailure?("입력 오디오 포맷을 사용할 수 없습니다.")
            state = .idle
            return
        }
        if let destination = recordingDestination, audioFileBox.currentFile == nil {
            do {
                audioFileBox.set(try AVAudioFile(
                    forWriting: destination,
                    settings: inputFormat.settings,
                    commonFormat: inputFormat.commonFormat,
                    interleaved: inputFormat.isInterleaved
                ))
                DeveloperConsole.shared.log(.info, category: "MeetingArchive", "audio recording started rate=\(inputFormat.sampleRate)")
            } catch {
                DeveloperConsole.shared.log(.warning, category: "MeetingArchive", "audio open failed code=\((error as NSError).code)")
            }
        }

        let audioFileBox = self.audioFileBox
        inputNode.installTap(onBus: 0, bufferSize: 4096, format: nil) { [weak request] buffer, _ in
            request?.append(buffer)
            audioFileBox.write(buffer)
        }
        hasInputTap = true

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
        scheduleSegmentTicker()
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

    private func scheduleSegmentTicker() {
        tickerWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            Task { @MainActor [weak self] in
                self?.tickSegment()
            }
        }
        tickerWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.segmentTickerInterval, execute: item)
    }

    private func tickSegment() {
        guard state == .running else { return }
        let now = Date()
        if Self.shouldAnalyze(pending: pendingText, previous: lastStableText,
            quietTime: now.timeIntervalSince(lastPartialAt), elapsed: now.timeIntervalSince(lastStableAt)) {
            lastStableText = pendingText
            lastStableAt = now
            onStable?(pendingText)
            DeveloperConsole.shared.log(.info, category: "MeetingSpeech", "stable chars=\(pendingText.count)")
        }
        scheduleSegmentTicker()
    }

    nonisolated static func shouldAnalyze(pending: String, previous: String,
                                         quietTime: TimeInterval, elapsed: TimeInterval) -> Bool {
        pending.trimmingCharacters(in: .whitespacesAndNewlines).count >= 2
            && pending != previous && (quietTime >= 1 || elapsed >= 4)
    }

    private func restartCycle() {
        guard state == .running else { return }
        flushRemainder()
        startRecognitionLoop()
    }

    private func handleRecognition(
        generation: Int,
        result: SFSpeechRecognitionResult?,
        error: Error?
    ) {
        guard generation == recognitionGeneration, state == .running else { return }

        if let result {
            consecutiveTaskErrors = 0
            let text = result.bestTranscription.formattedString
            if text != pendingText {
                pendingText = text
                lastPartialAt = Date()
                onPartial?(text)
                DeveloperConsole.shared.log(.info, category: "MeetingSpeech", "partial chars=\(text.count) final=\(result.isFinal)")
            }
            if result.isFinal {
                flushRemainder()
                startRecognitionLoop()
                return
            }
            if error == nil { return }
        }

        if let error {
            consecutiveTaskErrors += 1
            let nsError = error as NSError
            DeveloperConsole.shared.log(.warning, category: "MeetingSpeech", "error domain=\(nsError.domain) code=\(nsError.code) count=\(consecutiveTaskErrors)")
            if consecutiveTaskErrors >= 2, speechRecognizer?.supportsOnDeviceRecognition == true {
                prefersOnDevice = true
                onDeviceUntil = Date().addingTimeInterval(120)
            }
            flushRemainder()
            teardownEngine(keepAudioSession: true)
            guard consecutiveTaskErrors < 5 else {
                state = .idle
                onFailure?("음성 인식을 계속할 수 없습니다. 다시 시작해 주세요.")
                return
            }
            let generation = recognitionGeneration
            let item = DispatchWorkItem { [weak self] in
                Task { @MainActor [weak self] in
                    guard let self, self.recognitionGeneration == generation else { return }
                    self.startRecognitionLoop()
                }
            }
            restartWorkItem = item
            DispatchQueue.main.asyncAfter(deadline: .now() + min(Double(consecutiveTaskErrors), 4), execute: item)
        }
    }

    private func flushRemainder() {
        let remainder = pendingText.trimmingCharacters(in: .whitespacesAndNewlines)
        pendingText = ""
        guard !remainder.isEmpty else { return }
        onSegment?(remainder)
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
        tickerWorkItem?.cancel()
        tickerWorkItem = nil
        teardownTask()
        audioEngine.stop()
        if hasInputTap {
            audioEngine.inputNode.removeTap(onBus: 0)
            hasInputTap = false
        }
        if !keepAudioSession {
            try? AVAudioSession.sharedInstance().setActive(
                false,
                options: [.notifyOthersOnDeactivation]
            )
        }
    }
}

/// 입력 탭(오디오 스레드)과 중지(메인 스레드) 사이의 파일 접근을 보호한다.
final class MeetingAudioFileBox {
    private let lock = NSLock()
    private var file: AVAudioFile?

    var currentFile: AVAudioFile? {
        lock.lock()
        defer { lock.unlock() }
        return file
    }

    func set(_ newFile: AVAudioFile) {
        lock.lock()
        file = newFile
        lock.unlock()
    }

    func write(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        try? file?.write(from: buffer)
        lock.unlock()
    }

    func clear() {
        lock.lock()
        file = nil
        lock.unlock()
    }
}
