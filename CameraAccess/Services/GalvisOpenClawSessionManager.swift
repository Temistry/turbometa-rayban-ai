import Foundation
import UIKit

@MainActor
final class GalvisOpenClawSessionManager: ObservableObject {
    enum State: Equatable {
        case idle
        case requestingPermission
        case connecting
        case listening
        case waitingForResponse
        case followUp
        case waitingForWakeWord
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
    private var followUpTimeoutTask: Task<Void, Never>?
    private var backgroundObserver: NSObjectProtocol?
    private var isActive = false
    private var sessionGeneration = 0

    private let followUpSeconds: TimeInterval = 15
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
        isActive = true
        sessionGeneration += 1
        sessionTask = Task { [weak self] in
            await self?.runSession()
        }
    }

    func stop() {
        guard isActive || state != .stopped else { return }
        isActive = false
        followUpTimeoutTask?.cancel()
        followUpTimeoutTask = nil
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
            state = .connecting
            if openClaw.connectionState != .connected {
                openClaw.refreshGatewayTokenState()
                guard openClaw.isGatewayTokenConfigured else {
                    throw OpenClawConversationError.notConfigured
                }
                openClaw.ensureConnected(reason: "GalvisOpenClawSessionManager.runSession")
                try await waitForConnection()
            }

            try await conversationLoop()
        } catch is CancellationError {
            return
        } catch {
            guard isActive else { return }
            state = .error(error.localizedDescription)
            isActive = false
            recognizer.cancel()
            audioSession.deactivate()
        }
    }

    private func conversationLoop() async throws {
        var requiresWakeWord = false
        var nextTimeout: TimeInterval?

        while isActive && !Task.isCancelled {
            do {
                guard let question = try await listenForQuestion(
                    requiresWakeWord: requiresWakeWord,
                    timeout: nextTimeout
                ) else {
                    requiresWakeWord = true
                    nextTimeout = nil
                    continue
                }

                try await processQuestion(question)
                requiresWakeWord = false
                nextTimeout = followUpSeconds
                state = .followUp
            } catch is FollowUpTimeout {
                requiresWakeWord = true
                nextTimeout = nil
            }
        }
    }

    private struct FollowUpTimeout: Error {}

    private func listenForQuestion(
        requiresWakeWord: Bool,
        timeout: TimeInterval?
    ) async throws -> String? {
        state = requiresWakeWord ? .waitingForWakeWord : .listening
        transcript = ""

        if let timeout {
            followUpTimeoutTask?.cancel()
            followUpTimeoutTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                guard !Task.isCancelled else { return }
                await MainActor.run { self?.recognizer.cancel() }
            }
        }

        do {
            let recognized = try await recognizer.listen()
            followUpTimeoutTask?.cancel()
            followUpTimeoutTask = nil
            transcript = recognized

            if containsStopPhrase(recognized) {
                stop()
                return nil
            }

            if requiresWakeWord {
                return questionAfterWakeWord(recognized)
            }
            return recognized
        } catch is CancellationError {
            followUpTimeoutTask?.cancel()
            followUpTimeoutTask = nil
            guard isActive else { throw CancellationError() }
            if timeout != nil { throw FollowUpTimeout() }
            return nil
        }
    }

    private func processQuestion(_ question: String) async throws {
        guard !question.isEmpty else { return }

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

        guard let requestID = tts.enqueue(speechText) else {
            print("[Galvis][TTS][ERROR] 자동 음성 요청 실패 speechLength=\(speechText.count)")
            try restoreConversationSessionIfNeeded(activeGeneration: activeGeneration)
            return
        }

        print("[Galvis][TTS] 자동 음성 요청 접수 speechLength=\(speechText.count)")
        await waitForSpeech(requestID: requestID, speechLength: speechText.count)
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

    private func waitForConnection() async throws {
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline {
            switch openClaw.connectionState {
            case .connected:
                return
            case .error, .waitingForPairing:
                throw OpenClawConversationError.connectionFailed
            case .disconnected, .connecting:
                try await Task.sleep(nanoseconds: 200_000_000)
            }
        }
        throw OpenClawConversationError.connectionFailed
    }

    private func containsStopPhrase(_ text: String) -> Bool {
        let compact = text.replacingOccurrences(of: " ", with: "")
        return stopPhrases.contains { compact.contains($0.replacingOccurrences(of: " ", with: "")) }
    }

    private func questionAfterWakeWord(_ text: String) -> String? {
        guard let range = text.range(of: "갈비스", options: .caseInsensitive) else { return nil }
        return text[range.upperBound...]
            .trimmingCharacters(in: CharacterSet(charactersIn: " ,.!?。？！").union(.whitespacesAndNewlines))
    }
}
