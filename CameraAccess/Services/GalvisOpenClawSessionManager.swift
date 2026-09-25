import Foundation
import UIKit

enum GalvisConversationRecoveryAction: Equatable {
    case retryListening
    case reconnectThenListen
    case stop
}

enum GalvisConversationFailure: Equatable {
    case cancelled
    case emptyTranscript
    case speechUnavailable
    case permissionDenied
    case connectionFailed
    case disconnected
    case requestInProgress
    case responseTimeout
    case notConfigured
    case invalidImage
    case gatewayRejected
    case deliveryAmbiguous
    case transient
}

struct GalvisConversationRecoveryPolicy {
    static let maximumConsecutiveFailures = 5

    static func action(for failure: GalvisConversationFailure) -> GalvisConversationRecoveryAction {
        switch failure {
        case .emptyTranscript, .requestInProgress, .responseTimeout, .transient:
            return .retryListening
        case .connectionFailed, .disconnected:
            return .reconnectThenListen
        case .cancelled, .speechUnavailable, .permissionDenied, .notConfigured,
             .invalidImage, .gatewayRejected, .deliveryAmbiguous:
            return .stop
        }
    }

    static func failure(for error: Error) -> GalvisConversationFailure {
        if error is CancellationError {
            return .cancelled
        }

        if let recognitionError = error as? GalvisSpeechRecognizer.RecognitionError {
            switch recognitionError {
            case .emptyTranscript:
                return .emptyTranscript
            case .unavailable:
                return .speechUnavailable
            case .permissionDenied:
                return .permissionDenied
            }
        }

        if let conversationError = error as? OpenClawConversationError {
            switch conversationError {
            case .connectionFailed:
                return .connectionFailed
            case .disconnected:
                return .disconnected
            case .requestInProgress:
                return .requestInProgress
            case .responseTimeout:
                return .responseTimeout
            case .notConfigured:
                return .notConfigured
            case .invalidImage:
                return .invalidImage
            case .gatewayRejected:
                return .gatewayRejected
            case .deliveryAmbiguous:
                return .deliveryAmbiguous
            }
        }

        return .transient
    }

    static func shouldRetry(afterFailureCount failureCount: Int) -> Bool {
        failureCount < maximumConsecutiveFailures
    }

    static func retryDelayNanoseconds(forAttempt attempt: Int) -> UInt64 {
        let delays: [UInt64] = [250, 500, 1_000, 2_000, 3_000]
        let index = min(max(attempt, 1), delays.count) - 1
        return delays[index] * 1_000_000
    }
}

struct GalvisConversationLoopPolicy {
    private(set) var consecutiveFailures = 0

    mutating func recordSuccessfulTurn() {
        consecutiveFailures = 0
    }

    mutating func recoveryAction(
        for failure: GalvisConversationFailure
    ) -> GalvisConversationRecoveryAction {
        let action = GalvisConversationRecoveryPolicy.action(for: failure)
        guard action != .stop else { return .stop }
        guard GalvisConversationRecoveryPolicy.shouldRetry(
            afterFailureCount: consecutiveFailures
        ) else {
            return .stop
        }
        consecutiveFailures += 1
        return action
    }

    var retryDelayNanoseconds: UInt64 {
        GalvisConversationRecoveryPolicy.retryDelayNanoseconds(
            forAttempt: consecutiveFailures
        )
    }
}

@MainActor
final class GalvisOpenClawSessionManager: ObservableObject {
    enum State: Equatable {
        case idle
        case requestingPermission
        case connecting
        case listening
        case waitingForResponse
        case speaking
        case recoveringAudio
        case reconnecting
        case error(String)
        case stopped
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var transcript = ""
    @Published private(set) var lastAnswer = ""

    private let openClaw = OpenClawNodeService.shared
    private let recognizer = GalvisSpeechRecognizer()
    private let audioSession = GalvisAudioSessionController()
    private let tts = TTSService.shared
    private var sessionTask: Task<Void, Never>?
    private var backgroundObserver: NSObjectProtocol?
    private var isActive = false
    private var sessionGeneration = 0

    private let stopPhrases = ["갈비스 종료", "대화 종료", "그만 들어", "마이크 꺼"]

    init() {
        backgroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.stop() }
        }
    }

    deinit {
        if let backgroundObserver {
            NotificationCenter.default.removeObserver(backgroundObserver)
        }
    }

    func start() {
        guard !isActive else { return }
        print("[Galvis][ROUTE] 음성 대화 manager 시작")
        isActive = true
        sessionGeneration += 1
        sessionTask = Task { [weak self] in
            await self?.runSession()
        }
    }

    func stop() {
        guard isActive || state != .stopped else { return }
        isActive = false
        sessionTask?.cancel()
        sessionTask = nil
        recognizer.cancel()
        tts.stop()
        openClaw.cancelPendingConversation()
        audioSession.deactivate()
        state = .stopped
        print("[Galvis][INFO] 음성 대화 종료")
    }

    func restartListening() {
        guard !isActive else { return }
        start()
    }

    private func runSession() async {
        state = .requestingPermission
        guard await GalvisSpeechRecognizer.requestAuthorization() else {
            state = .error("마이크와 음성 인식 권한을 허용해 주세요.")
            isActive = false
            return
        }

        do {
            try audioSession.activateConversationSession()
            try await connectIfNeeded(reason: "GalvisOpenClawSessionManager.runSession")
            try await conversationLoop()
        } catch is CancellationError {
            return
        } catch {
            guard isActive else { return }
            state = .error(error.localizedDescription)
            isActive = false
            recognizer.cancel()
            tts.stop()
            audioSession.deactivate()
        }
    }

    private func conversationLoop() async throws {
        var loopPolicy = GalvisConversationLoopPolicy()

        while isActive && !Task.isCancelled {
            do {
                try audioSession.activateConversationSession()
                try await connectIfNeeded(
                    reason: "GalvisOpenClawSessionManager.conversationLoop",
                    connectingState: .reconnecting
                )
                state = .listening
                transcript = ""

                let recognized = try await recognizer.listen()
                transcript = recognized

                if containsStopPhrase(recognized) {
                    stop()
                    return
                }

                try await processQuestion(recognized)
                loopPolicy.recordSuccessfulTurn()
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                guard isActive, !Task.isCancelled else { throw CancellationError() }
                try await recoverListening(after: error, loopPolicy: &loopPolicy)
            }
        }
    }

    private func recoverListening(
        after error: Error,
        loopPolicy: inout GalvisConversationLoopPolicy
    ) async throws {
        let failure = GalvisConversationRecoveryPolicy.failure(for: error)
        let action = loopPolicy.recoveryAction(for: failure)
        guard action != .stop else { throw error }

        let nsError = error as NSError
        print(
            "[Galvis][WARN] 대화 턴 복구 action=\(String(describing: action)) "
            + "attempt=\(loopPolicy.consecutiveFailures) domain=\(nsError.domain) code=\(nsError.code)"
        )

        recognizer.reset()

        switch action {
        case .retryListening:
            state = .recoveringAudio
            try audioSession.activateConversationSession()

        case .reconnectThenListen:
            try await connectIfNeeded(
                reason: "GalvisOpenClawSessionManager.recoverListening",
                connectingState: .reconnecting
            )

        case .stop:
            throw error
        }

        try await Task.sleep(
            nanoseconds: loopPolicy.retryDelayNanoseconds
        )
    }

    private func processQuestion(_ question: String) async throws {
        guard !question.isEmpty else {
            throw GalvisSpeechRecognizer.RecognitionError.emptyTranscript
        }

        recognizer.cancel()
        state = .waitingForResponse
        let answer = try await openClaw.ask(question)
        lastAnswer = answer

        guard let speechText = GalvisSpeechResponseFormatter.speechText(from: answer) else {
            print("[Galvis][TTS][WARN] 읽을 수 있는 최종 답변 없음 answerLength=\(answer.count)")
            return
        }

        try await speakAnswerAndRestoreConversation(speechText)
    }

    private func speakAnswerAndRestoreConversation(_ speechText: String) async throws {
        let activeGeneration = sessionGeneration
        audioSession.deactivate()
        state = .speaking

        if let requestID = tts.enqueue(speechText) {
            print("[Galvis][TTS] 자동 음성 요청 접수 speechLength=\(speechText.count)")
            await waitForSpeech(requestID: requestID, speechLength: speechText.count)
        } else {
            print("[Galvis][TTS][ERROR] 자동 음성 요청 실패 speechLength=\(speechText.count)")
        }

        try restoreConversationSessionIfNeeded(activeGeneration: activeGeneration)
    }

    private func waitForSpeech(requestID: UUID, speechLength: Int) async {
        let startDeadline = Date().addingTimeInterval(4)
        var didStart = false

        while isActive && !Task.isCancelled && Date() < startDeadline {
            switch tts.playbackState {
            case let .speaking(activeRequestID) where activeRequestID == requestID:
                didStart = true
            case .idle:
                return
            case let .failed(activeRequestID) where activeRequestID == requestID:
                return
            case let .queued(activeRequestID) where activeRequestID == requestID:
                break
            case .queued, .speaking, .failed:
                return
            }

            if didStart { break }
            do {
                try await Task.sleep(nanoseconds: 100_000_000)
            } catch {
                return
            }
        }

        guard didStart else {
            print("[Galvis][TTS][ERROR] 자동 음성 시작 timeout speechLength=\(speechLength)")
            tts.stop()
            return
        }

        let estimatedDuration = min(45.0, max(8.0, Double(speechLength) / 5.0 + 5.0))
        let finishDeadline = Date().addingTimeInterval(estimatedDuration)
        while isActive && !Task.isCancelled && Date() < finishDeadline {
            guard tts.isActive(requestID: requestID) else { return }
            do {
                try await Task.sleep(nanoseconds: 100_000_000)
            } catch {
                return
            }
        }

        if tts.isActive(requestID: requestID) {
            print("[Galvis][TTS][WARN] 자동 음성 완료 timeout speechLength=\(speechLength)")
            tts.stop()
        }
    }

    private func restoreConversationSessionIfNeeded(
        activeGeneration: Int
    ) throws {
        guard isActive, !Task.isCancelled, sessionGeneration == activeGeneration else { return }
        try audioSession.activateConversationSession()
        print("[Galvis][AUDIO] TTS 이후 음성 대화 세션 복구 완료")
    }

    private func connectIfNeeded(
        reason: String,
        connectingState: State = .connecting
    ) async throws {
        if openClaw.connectionState == .connected { return }

        state = connectingState
        openClaw.refreshGatewayTokenState()
        guard openClaw.isGatewayTokenConfigured else {
            throw OpenClawConversationError.notConfigured
        }
        openClaw.ensureConnected(reason: reason)
        try await waitForConnection()
    }

    private func waitForConnection() async throws {
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline {
            switch openClaw.connectionState {
            case .connected:
                return
            case .waitingForPairing:
                throw OpenClawConversationError.connectionFailed
            case .error:
                openClaw.ensureConnected(reason: "GalvisOpenClawSessionManager.waitForConnection")
            case .disconnected, .connecting:
                break
            }
            try await Task.sleep(nanoseconds: 200_000_000)
        }
        throw OpenClawConversationError.connectionFailed
    }

    private func containsStopPhrase(_ text: String) -> Bool {
        let compact = text.replacingOccurrences(of: " ", with: "")
        return stopPhrases.contains { compact.contains($0.replacingOccurrences(of: " ", with: "")) }
    }
}
