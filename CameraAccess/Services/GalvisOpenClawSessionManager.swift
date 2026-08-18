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
        case speaking
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
        openClaw.cancelPendingConversation()
        tts.stop()
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
                guard openClaw.loadGatewayToken() != nil else {
                    throw OpenClawConversationError.notConfigured
                }
                openClaw.connect()
                try await waitForConnection()
            }

            try await speak("OpenClaw에 연결했습니다. 말씀하세요.")
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
        guard !question.isEmpty else {
            try await speak("무엇을 도와드릴까요?")
            return
        }

        recognizer.cancel()
        state = .waitingForResponse
        let answer = try await openClaw.ask(question)
        lastAnswer = answer

        if let speechText = GalvisSpeechResponseFormatter.speechText(from: answer) {
            try await speak(speechText)
        }
    }

    private func speak(_ text: String) async throws {
        recognizer.cancel()
        state = .speaking
        try await tts.speakAndWait(text, preservesAudioSession: true)
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
