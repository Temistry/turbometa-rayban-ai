/*
 * 회의 통역기 전사 서비스
 *
 * 안경(HFP/LE 오디오 입력)을 우선 라우팅해 iOS 음성 인식으로 한국어 발화를
 * 연속 전사한다. 귓속말(TTS) 재생은 오디오 세션을 .playback으로 바꾸므로
 * pause/resume 시마다 .playAndRecord 세션을 다시 구성해 입력을 되찾는다.
 *
 * 품질과 반응성:
 * - 기본은 서버 음성 인식(전문용어 정확도) + 문장부호 추가.
 * - 4초마다 부분 인식 결과에서 문장 구분자까지의 증분만 발행해 전사가 즉시 흐른다.
 * - 연속 오류(네트워크 불가 등) 2회부터는 온디바이스 인식으로 자동 강하한다.
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
    /// 시각 보조가 뽑은 화면 용어. 인식 작업 시작 시 contextualStrings로 주입된다.
    var contextualTerms: [String] = []

    private let audioEngine = AVAudioEngine()
    private let speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "ko-KR"))
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var restartWorkItem: DispatchWorkItem?
    private var tickerWorkItem: DispatchWorkItem?
    private var pendingText = ""
    private var emittedText = ""
    private var recognitionGeneration = 0
    private var consecutiveTaskErrors = 0
    private var prefersOnDevice = false
    private var hasInputTap = false

    /// 부분 결과 증분 발행 주기(초).
    static let segmentTickerInterval: TimeInterval = 4
    /// 구분자 없이 이 길이 이상 쌓이면 강제로 발행한다.
    static let hardFlushLength = 40

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
        emittedText = ""
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
        audioEngine.stop()
        if hasInputTap {
            audioEngine.inputNode.removeTap(onBus: 0)
            hasInputTap = false
        }
        teardownTask()
        pendingText = ""
        emittedText = ""

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
        let inputFormat = inputNode.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            onFailure?("입력 오디오 포맷을 사용할 수 없습니다.")
            state = .idle
            return
        }

        inputNode.installTap(onBus: 0, bufferSize: 4096, format: nil) { [weak request] buffer, _ in
            request?.append(buffer)
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
        emitAvailableDelta()
        scheduleSegmentTicker()
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
            pendingText = result.bestTranscription.formattedString
            if result.isFinal {
                flushRemainder()
                startRecognitionLoop()
            }
            return
        }

        if error != nil {
            consecutiveTaskErrors += 1
            if consecutiveTaskErrors >= 2 {
                prefersOnDevice = true
            }
            restartWorkItem?.cancel()
            flushRemainder()
            startRecognitionLoop()
        }
    }

    private func emitAvailableDelta() {
        guard let delta = Self.nextEmitDelta(pending: pendingText, emitted: emittedText) else {
            return
        }
        emittedText = delta.newEmitted
        onSegment?(delta.emit)
    }

    private func flushRemainder() {
        let common = Self.commonPrefixLength(pendingText, emittedText)
        let remainder = String(pendingText.dropFirst(common))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        pendingText = ""
        emittedText = ""
        guard remainder.count >= 2 else { return }
        onSegment?(remainder)
    }

    // MARK: - 증분 분할(단위 테스트용 순수 함수)

    /// 아직 발행하지 않은 텍스트에서 문장 구분자까지의 증분을 뽑는다.
    /// 구분자가 없으면 hardFlushLength 이상일 때만 전체를 발행한다.
    nonisolated static func nextEmitDelta(
        pending: String,
        emitted: String
    ) -> (emit: String, newEmitted: String)? {
        guard !pending.isEmpty else { return nil }

        let common = commonPrefixLength(pending, emitted)
        let tail = String(pending.dropFirst(common))
        guard !tail.isEmpty else { return nil }

        let delimiters: Set<Character> = [".", "?", "!", "…", ","]
        if let cutIndex = tail.lastIndex(where: { delimiters.contains($0) }) {
            let emitPart = String(tail[tail.startIndex...cutIndex])
            let emit = emitPart.trimmingCharacters(in: .whitespacesAndNewlines)
            guard emit.count >= 2 else { return nil }
            let newEmitted = String(pending.prefix(common + emitPart.count))
            return (emit, newEmitted)
        }

        if tail.count >= hardFlushLength {
            let emit = tail.trimmingCharacters(in: .whitespacesAndNewlines)
            guard emit.count >= 2 else { return nil }
            return (emit, pending)
        }

        return nil
    }

    nonisolated static func commonPrefixLength(_ a: String, _ b: String) -> Int {
        let aChars = Array(a)
        let bChars = Array(b)
        var index = 0
        while index < aChars.count && index < bChars.count && aChars[index] == bChars[index] {
            index += 1
        }
        return index
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
