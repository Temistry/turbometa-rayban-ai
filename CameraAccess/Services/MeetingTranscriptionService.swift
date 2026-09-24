/*
 * 회의 통역기 전사 서비스
 *
 * 입력 마이크는 설정(MeetingMicMode)을 따른다.
 * - 폰(기본): 폰 마이크로 상대 말을 듣고, 귓속말은 안경·이어폰(A2DP)으로 보낸다.
 *   안경·에어팟 마이크는 착용자 입 방향만 잡도록 설계돼 상대 목소리를 깎는다.
 * - 안경·이어폰: 블루투스 통화(HFP) 마이크. 내 말 위주 기록에 쓴다.
 * iOS는 한 앱에 입력을 하나만 연결하므로 여러 마이크를 동시에 쓰지 않는다.
 * 회의 귓속말은 동일한 playAndRecord 세션을 유지한다.
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

/// 회의 입력 마이크 선택. 저장값이 없으면 폰 마이크(상대 말 우선)다.
enum MeetingMicMode: String, CaseIterable, Identifiable {
    case phone
    case headset

    static let storageKey = "meeting.micMode"

    var id: String { rawValue }
    var titleKey: String { "settings.mic.\(rawValue)" }
    var detailKey: String { "settings.mic.\(rawValue).detail" }

    static func resolve(stored: String?) -> MeetingMicMode {
        stored.flatMap(MeetingMicMode.init(rawValue:)) ?? .phone
    }

    static var current: MeetingMicMode {
        resolve(stored: UserDefaults.standard.string(forKey: storageKey))
    }
}

/// 10초 구간의 입력 음량 요약(dBFS, 0이 최대).
struct MeetingInputWindow: Equatable {
    let buffers: Int
    let averageDb: Float
    let peakDb: Float
    /// 말소리 수준(speechThresholdDb 이상) 버퍼 비율.
    let speechRatio: Double
}

/// 입력 탭(오디오 스레드)에서 음량을 모으고 메인 스레드에서 구간 단위로 꺼낸다.
final class MeetingInputMeter {
    static let floorDb: Float = -100
    /// 1~2m 거리 대화는 대략 -40~-25dBFS. 이보다 작으면 말소리로 보지 않는다.
    static let speechThresholdDb: Float = -45
    /// 30초 내내 최대 음량이 이보다 작으면 마이크가 사실상 아무것도 못 듣는 상태로 본다.
    static let quietPeakDb: Float = -50

    private let lock = NSLock()
    private var count = 0
    private var sumDb: Float = 0
    private var peak: Float = MeetingInputMeter.floorDb
    private var speech = 0

    func add(_ buffer: AVAudioPCMBuffer) {
        let db = Self.rmsDecibels(buffer)
        lock.lock()
        count += 1
        sumDb += db
        peak = max(peak, db)
        if db >= Self.speechThresholdDb { speech += 1 }
        lock.unlock()
    }

    func drain() -> MeetingInputWindow? {
        lock.lock()
        defer {
            count = 0
            sumDb = 0
            peak = Self.floorDb
            speech = 0
            lock.unlock()
        }
        guard count > 0 else { return nil }
        return MeetingInputWindow(
            buffers: count,
            averageDb: sumDb / Float(count),
            peakDb: peak,
            speechRatio: Double(speech) / Double(count)
        )
    }

    static func rmsDecibels(_ buffer: AVAudioPCMBuffer) -> Float {
        let frames = Int(buffer.frameLength)
        guard frames > 0 else { return floorDb }
        if let channel = buffer.floatChannelData?[0] {
            return rmsDecibels(UnsafeBufferPointer(start: channel, count: frames))
        }
        if let channel = buffer.int16ChannelData?[0] {
            return rmsDecibels(UnsafeBufferPointer(start: channel, count: frames).map { Float($0) / 32768 })
        }
        return floorDb
    }

    static func rmsDecibels<S: Sequence>(_ samples: S) -> Float where S.Element == Float {
        var sum: Float = 0
        var n = 0
        for sample in samples {
            sum += sample * sample
            n += 1
        }
        guard n > 0, sum > 0 else { return floorDb }
        return max(floorDb, 10 * log10(sum / Float(n)))
    }

    /// 최근 구간들 모두 최대 음량이 기준 미만이면 참. 구간이 부족하면 판단하지 않는다.
    static func isQuiet(_ windows: [MeetingInputWindow], required: Int = 3) -> Bool {
        guard windows.count >= required else { return false }
        return windows.suffix(required).allSatisfy { $0.peakDb < quietPeakDb }
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
    /// 10초마다 입력 음량 구간과 "마이크 소리 작음" 판단을 전달한다.
    var onInputQuality: ((MeetingInputWindow?, Bool) -> Void)?
    /// 회의 시작 전에 설정한다. start() 이후 바꾸면 다음 세션 구성부터 적용된다.
    var micMode: MeetingMicMode = .phone
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
    private var interruptionObserver: NSObjectProtocol?
    private var routeObserver: NSObjectProtocol?
    private var engineRetryCount = 0
    private var engineRetryWorkItem: DispatchWorkItem?
    private let inputMeter = MeetingInputMeter()
    private var meterWorkItem: DispatchWorkItem?
    private var recentWindows: [MeetingInputWindow] = []
    private var recognizedChars = 0
    /// 폰 스피커로 귓속말이 나올 때만 에코 제거·잡음 억제를 켠다.
    private var usesVoiceProcessing = true

    /// 입력 품질 요약 주기(초).
    static let meterInterval: TimeInterval = 10

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
        registerSystemObservers()

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
        recentWindows = []
        recognizedChars = 0
        _ = inputMeter.drain()
        scheduleMeter()
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
        removeSystemObservers()
        meterWorkItem?.cancel()
        meterWorkItem = nil
        recentWindows = []
    }

    private func configureAudioSession() throws {
        let session = AVAudioSession.sharedInstance()
        var dataSourceName = "-"
        switch micMode {
        case .phone:
            // .allowBluetooth(HFP)를 빼야 안경·에어팟이 입력을 가져가지 않는다.
            // 출력은 연결된 블루투스 기기(A2DP)로, 없으면 폰 스피커로 나간다.
            try session.setCategory(
                .playAndRecord,
                mode: .default,
                options: [.allowBluetoothA2DP, .defaultToSpeaker]
            )
            try session.setActive(true)
            if let builtIn = session.availableInputs?.first(where: { $0.portType == .builtInMic }) {
                try? session.setPreferredInput(builtIn)
                dataSourceName = Self.preferOmnidirectional(builtIn)
            }
        case .headset:
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
        }

        let outputs = session.currentRoute.outputs.map(\.portType)
        usesVoiceProcessing = micMode == .headset || Self.needsEchoCancellation(outputs: outputs)
        inputRouteName = session.currentRoute.inputs.first?.portName ?? "-"
        DeveloperConsole.shared.log(.info, category: "MeetingAudio", "mic=\(micMode.rawValue) input=\(inputRouteName) source=\(dataSourceName) outputs=\(outputs.map(\.rawValue).joined(separator: ",")) voiceProcessing=\(usesVoiceProcessing) rate=\(session.sampleRate)")
    }

    /// 귓속말이 폰 스피커·수화기로 나오면 마이크가 되받으므로 에코 제거가 필요하다.
    nonisolated static func needsEchoCancellation(outputs: [AVAudioSession.Port]) -> Bool {
        outputs.contains { $0 == .builtInSpeaker || $0 == .builtInReceiver }
    }

    /// 테이블 위 폰이 주변 사람 목소리를 고르게 받도록 무지향 패턴의 아래쪽 마이크를 고른다.
    private static func preferOmnidirectional(_ port: AVAudioSessionPortDescription) -> String {
        guard let sources = port.dataSources, !sources.isEmpty else { return "-" }
        let omni = sources.filter { $0.supportedPolarPatterns?.contains(.omnidirectional) == true }
        guard let chosen = omni.first(where: { $0.orientation == .bottom }) ?? omni.first ?? sources.first else {
            return "-"
        }
        try? port.setPreferredDataSource(chosen)
        if chosen.supportedPolarPatterns?.contains(.omnidirectional) == true {
            try? chosen.setPreferredPolarPattern(.omnidirectional)
        }
        return chosen.dataSourceName
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
        if inputNode.isVoiceProcessingEnabled != usesVoiceProcessing {
            do { try inputNode.setVoiceProcessingEnabled(usesVoiceProcessing) }
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
        let inputMeter = self.inputMeter
        inputNode.installTap(onBus: 0, bufferSize: 4096, format: nil) { [weak request] buffer, _ in
            request?.append(buffer)
            audioFileBox.write(buffer)
            inputMeter.add(buffer)
        }
        hasInputTap = true

        audioEngine.prepare()
        do {
            try audioEngine.start()
            engineRetryCount = 0
        } catch {
            // 방해(통화·시리) 직후에는 즉시 실패 대신 몇 차례 재시도한다.
            engineRetryCount += 1
            DeveloperConsole.shared.log(.warning, category: "MeetingSpeech", "engine start failed code=\((error as NSError).code) count=\(engineRetryCount)")
            guard engineRetryCount < 3 else {
                onFailure?("오디오 엔진을 시작하지 못했습니다. 다시 시작해 주세요.")
                state = .idle
                return
            }
            let generation = recognitionGeneration
            let item = DispatchWorkItem { [weak self] in
                Task { @MainActor [weak self] in
                    guard let self, self.recognitionGeneration == generation, self.state == .running else { return }
                    self.startRecognitionLoop()
                }
            }
            engineRetryWorkItem?.cancel()
            engineRetryWorkItem = item
            DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: item)
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

    private func scheduleMeter() {
        meterWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            Task { @MainActor [weak self] in
                self?.tickMeter()
            }
        }
        meterWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.meterInterval, execute: item)
    }

    /// 마이크 비교용 기록: 음량, 말소리 비율, 그 구간에 전사된 글자 수.
    private func tickMeter() {
        guard state != .idle else { return }
        let window = inputMeter.drain()
        let chars = recognizedChars
        recognizedChars = 0
        if state == .running {
            if let window {
                recentWindows.append(window)
                if recentWindows.count > 6 { recentWindows.removeFirst(recentWindows.count - 6) }
                DeveloperConsole.shared.log(
                    .info,
                    category: "MeetingMic",
                    "mic=\(micMode.rawValue) input=\(inputRouteName) avg=\(String(format: "%.0f", window.averageDb))dB peak=\(String(format: "%.0f", window.peakDb))dB speech=\(Int(window.speechRatio * 100))% chars=\(chars)"
                )
            }
            onInputQuality?(window, MeetingInputMeter.isQuiet(recentWindows))
        }
        scheduleMeter()
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
                let confidences = result.bestTranscription.segments.map(\.confidence).filter { $0 > 0 }
                if !confidences.isEmpty {
                    let average = confidences.reduce(0, +) / Float(confidences.count)
                    DeveloperConsole.shared.log(.info, category: "MeetingSpeech", "final mic=\(micMode.rawValue) confidence=\(String(format: "%.2f", average)) chars=\(text.count)")
                }
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
        recognizedChars += remainder.count
        onSegment?(remainder)
    }

    private func teardownTask() {
        recognitionGeneration += 1
        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionRequest?.endAudio()
        recognitionRequest = nil
    }

    private func registerSystemObservers() {
        guard interruptionObserver == nil else { return }
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            Task { @MainActor [weak self] in
                self?.handleInterruption(notification)
            }
        }
        routeObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            Task { @MainActor [weak self] in
                self?.handleRouteChange(notification)
            }
        }
    }

    private func removeSystemObservers() {
        if let interruptionObserver {
            NotificationCenter.default.removeObserver(interruptionObserver)
        }
        if let routeObserver {
            NotificationCenter.default.removeObserver(routeObserver)
        }
        interruptionObserver = nil
        routeObserver = nil
        engineRetryWorkItem?.cancel()
        engineRetryWorkItem = nil
    }

    private func handleInterruption(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let typeRaw = userInfo[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeRaw) else { return }
        switch type {
        case .began:
            DeveloperConsole.shared.log(.warning, category: "MeetingAudio", "interruption began")
        case .ended:
            DeveloperConsole.shared.log(.info, category: "MeetingAudio", "interruption ended")
            recoverSession()
        @unknown default:
            break
        }
    }

    private func handleRouteChange(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let reasonRaw = userInfo[AVAudioSessionRouteChangeReasonKey] as? UInt,
              let reason = AVAudioSession.RouteChangeReason(rawValue: reasonRaw),
              reason == .oldDeviceUnavailable || reason == .newDeviceAvailable else { return }
        DeveloperConsole.shared.log(.info, category: "MeetingAudio", "route changed reason=\(reason.rawValue)")
        recoverSession()
    }

    /// 방해·라우트 변경 뒤 세션을 다시 구성하고 전사를 이어간다.
    private func recoverSession() {
        guard state == .running else { return }
        do {
            try configureAudioSession()
        } catch {
            DeveloperConsole.shared.log(.warning, category: "MeetingAudio", "recover failed code=\((error as NSError).code)")
            return
        }
        startRecognitionLoop()
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
