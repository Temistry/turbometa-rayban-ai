/*
 * 회의 통역기 뷰모델
 *
 * 전사 세그먼트마다 Jev로 개입 여부를 판정한다(신경 반사).
 * - 레인 A(설명): 신뢰도 임계 + 쿨다운 통과 시 Gemini 설명을 저음량 귓속말로 재생.
 * - 레인 B(근거): 검증 가능 주장은 Gemini 검색 그라운딩으로 링크 카드 생성.
 * Jev 오류는 fail-stop: 에러 코드를 표시하고 회의 통역을 즉시 중지한다.
 */

import Combine
import Foundation
import UIKit

enum MeetingPolicy {
    static let whisperCooldown: TimeInterval = 30
    static let whisperConfidenceThreshold = 0.85

    static func whisperAllowed(
        lastWhisperAt: Date?,
        now: Date,
        minInterval: TimeInterval = whisperCooldown
    ) -> Bool {
        guard let lastWhisperAt else { return true }
        return now.timeIntervalSince(lastWhisperAt) >= minInterval
    }
}

@MainActor
final class MeetingInterpreterViewModel: ObservableObject {
    enum RunState: Equatable {
        case idle
        case listening
    }

    enum Failure: Equatable {
        case jev(code: String, message: String)
        case microphone(String)
    }

    struct WhisperEvent: Identifiable, Equatable {
        enum State: Equatable {
            case speaking
            case spoken
            case failed
        }

        let id = UUID()
        let term: String
        let text: String
        let confidence: Double
        var state: State
    }

    struct TranscriptLine: Identifiable, Equatable {
        let id = UUID()
        let timestamp: Date
        let text: String
        var whisper: WhisperEvent?
    }

    enum FactState: Equatable {
        case pending
        case done
        case failed
    }

    struct FactCard: Identifiable, Equatable {
        let id = UUID()
        let claim: String
        var state: FactState = .pending
        var summary: String?
        var links: [MeetingFactLink] = []
    }

    @Published private(set) var lines: [TranscriptLine] = []
    @Published private(set) var factCards: [FactCard] = []
    @Published private(set) var runState: RunState = .idle
    @Published private(set) var failure: Failure?
    @Published private(set) var isSpeakingWhisper = false
    @Published private(set) var inputRouteName = "-"
    @Published private(set) var jevReady = false
    @Published private(set) var isStarting = false
    @Published private(set) var isStopping = false
    @Published private(set) var isDescribingPhoto = false
    @Published private(set) var photoError: String?

    /// 설정의 시각 보조 토글. 기본값은 켜짐이다.
    static var visualAssistEnabled: Bool {
        guard UserDefaults.standard.object(forKey: "meeting.visualAssist") != nil else {
            return true
        }
        return UserDefaults.standard.bool(forKey: "meeting.visualAssist")
    }

    let streamViewModel: StreamSessionViewModel

    private let transcription = MeetingTranscriptionService()
    private let jev = JevClient.shared
    private let gemini = MeetingGeminiService()
    private let tts = TTSService.shared
    private var visualAssist: VisualAssistService?
    private var sceneSummary: String?
    private var lastWhisperAt: Date?
    private var isPausingForWhisper = false
    private var activeWhisperRequestID: UUID?
    private var sawWhisperPlayback = false
    private var playbackCancellable: AnyCancellable?
    private var recentUtterances: [String] = []
    private var generation = UUID()
    private var startTask: Task<Void, Never>?
    private var photoTask: Task<Void, Never>?
    private var isPreparingWhisper = false

    init(streamViewModel: StreamSessionViewModel) {
        self.streamViewModel = streamViewModel

        if Self.visualAssistEnabled {
            let visualAssist = VisualAssistService(streamViewModel: streamViewModel)
            visualAssist.onContext = { [weak self] context in
                self?.transcription.contextualTerms = context.terms
                self?.sceneSummary = context.scene
            }
            self.visualAssist = visualAssist
        }

        transcription.onSegment = { [weak self] text in
            self?.handleUtterance(text)
        }
        transcription.onFailure = { [weak self] message in
            self?.failMicrophone(message)
        }
        playbackCancellable = tts.$playbackState
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                self?.handlePlaybackStateChange(state)
            }
    }

    func start() {
        guard runState == .idle, !isStarting, !isStopping, !isDescribingPhoto, !isSpeakingWhisper else { return }
        failure = nil

        guard JevClient.storedAPIKey != nil else {
            failure = .jev(
                code: JevClientError.missingAPIKey.code,
                message: "Jev API 키가 설정되지 않았습니다. 설정에서 TypeSafe Jev API Key를 등록하세요."
            )
            return
        }

        isStarting = true
        let generation = self.generation
        startTask = Task {
            defer { if generation == self.generation { isStarting = false } }
            do {
                try await transcription.start()
                guard generation == self.generation, !Task.isCancelled else { return }
                guard transcription.state == .running else { return }
                inputRouteName = transcription.inputRouteName
                runState = .listening
                visualAssist?.start()
            } catch {
                guard generation == self.generation, !Task.isCancelled else { return }
                let message = (error as? MeetingTranscriptionError)?.message
                    ?? error.localizedDescription
                failMicrophone(message)
            }
        }
    }

    func stop() {
        guard !isStopping else { return }
        isStopping = true
        generation = UUID()
        runState = .idle
        let pendingStart = startTask
        let pendingPhoto = photoTask
        startTask?.cancel()
        startTask = nil
        photoTask?.cancel()
        photoTask = nil
        isStarting = false
        isDescribingPhoto = false
        isPreparingWhisper = false
        transcription.stop()
        tts.stop()
        Task {
            await pendingStart?.value
            await pendingPhoto?.value
            if let visualAssist {
                await visualAssist.stop()
            } else {
                await streamViewModel.stopSession()
            }
            isStopping = false
        }
        runState = .idle
        isSpeakingWhisper = false
        isPausingForWhisper = false
        activeWhisperRequestID = nil
        sawWhisperPlayback = false
    }

    private func handleUtterance(_ text: String) {
        guard failure == nil, runState == .listening else { return }

        let line = TranscriptLine(timestamp: Date(), text: text)
        lines.append(line)
        if lines.count > 200 {
            lines.removeFirst(lines.count - 200)
        }

        recentUtterances.append(text)
        if recentUtterances.count > 6 {
            recentUtterances.removeFirst(recentUtterances.count - 6)
        }

        let lineID = line.id
        Task {
            await processUtterance(text, lineID: lineID)
        }
    }

    private func processUtterance(_ text: String, lineID: UUID) async {
        guard runState == .listening, failure == nil else { return }
        let generation = self.generation
        let previous = recentUtterances.count > 1
            ? recentUtterances[recentUtterances.count - 2]
            : nil

        do {
            let decision = try await jev.evaluate(
                utterance: text,
                previousUtterance: previous
            )
            guard generation == self.generation, runState == .listening else { return }
            jevReady = true

            if decision.lane == .factcheck {
                beginFactCheck(claim: text)
            }

            let now = Date()
            if !isDescribingPhoto, !isSpeakingWhisper, !isPreparingWhisper,
               decision.needsExplanation,
               decision.explanationConfidence >= MeetingPolicy.whisperConfidenceThreshold,
               MeetingPolicy.whisperAllowed(lastWhisperAt: lastWhisperAt, now: now) {
                lastWhisperAt = now
                await speakExplanation(
                    for: text,
                    lineID: lineID,
                    confidence: decision.explanationConfidence
                )
            }
        } catch let error as JevClientError {
            guard generation == self.generation else { return }
            failStopJev(code: error.code, message: error.message)
        } catch {
            guard generation == self.generation else { return }
            failStopJev(
                code: JevClientError.invalidResponse.code,
                message: JevClientError.invalidResponse.message
            )
        }
    }

    private func beginFactCheck(claim: String) {
        let generation = self.generation
        let card = FactCard(claim: claim)
        factCards.insert(card, at: 0)
        if factCards.count > 20 {
            factCards.removeLast(factCards.count - 20)
        }

        let cardID = card.id
        Task {
            do {
                let result = try await gemini.factCheck(claim: claim)
                guard generation == self.generation else { return }
                updateFactCard(cardID) {
                    $0.state = .done
                    $0.summary = result.summary
                    $0.links = result.links
                }
            } catch {
                guard generation == self.generation else { return }
                updateFactCard(cardID) {
                    $0.state = .failed
                }
            }
        }
    }

    private func speakExplanation(
        for utterance: String,
        lineID: UUID,
        confidence: Double
    ) async {
        let generation = self.generation
        isPreparingWhisper = true
        defer { if generation == self.generation { isPreparingWhisper = false } }
        let context = recentUtterances.count > 1
            ? recentUtterances[recentUtterances.count - 2]
            : ""

        do {
            let explanation = try await gemini.explain(
                utterance: utterance,
                recentContext: context,
                sceneContext: sceneSummary
            )
            guard generation == self.generation, runState == .listening,
                  !isDescribingPhoto, !isSpeakingWhisper else { return }
            updateLine(lineID) {
                $0.whisper = WhisperEvent(
                    term: explanation.term,
                    text: explanation.text,
                    confidence: confidence,
                    state: .speaking
                )
            }
            transcription.pause()
            isPausingForWhisper = true
            isSpeakingWhisper = true
            if let requestID = tts.enqueue(explanation.text, volume: 0.35) {
                activeWhisperRequestID = requestID
            } else {
                updateLine(lineID) {
                    $0.whisper?.state = .failed
                }
                isSpeakingWhisper = false
                isPausingForWhisper = false
                if runState == .listening {
                    transcription.resume()
                }
            }
        } catch {
            guard generation == self.generation else { return }
            updateLine(lineID) {
                $0.whisper = WhisperEvent(
                    term: "",
                    text: "",
                    confidence: confidence,
                    state: .failed
                )
            }
        }
    }

    func describeCurrentScene() {
        guard failure == nil, !isStarting, !isStopping, !isDescribingPhoto,
              !isSpeakingWhisper else { return }
        isDescribingPhoto = true
        photoError = nil
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        let generation = self.generation
        photoTask = Task {
            let temporaryStream = runState == .idle || visualAssist == nil
            defer {
                if generation == self.generation { isDescribingPhoto = false }
            }
            do {
                guard JevClient.storedAPIKey != nil else { throw JevClientError.missingAPIKey }
                try Task.checkCancellation()
                guard generation == self.generation else { return }
                if streamViewModel.streamingStatus == .stopped {
                    await streamViewModel.handleStartStreaming()
                }
                for _ in 0..<80 {
                    try Task.checkCancellation()
                    if streamViewModel.streamingStatus == .streaming { break }
                    try await Task.sleep(nanoseconds: 100_000_000)
                }
                guard streamViewModel.streamingStatus == .streaming else {
                    throw StreamCaptureError.captureInterrupted
                }
                let photo = try await streamViewModel.capturePhotoResult(owner: .meeting, timeout: 10)
                try Task.checkCancellation()
                print("[Meeting][PHOTO] captured width=\(photo.image.cgImage?.width ?? 0) height=\(photo.image.cgImage?.height ?? 0) bytes=\(photo.jpegData.count)")
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                if temporaryStream { await streamViewModel.stopSession() }
                // Capture immediately; verify Jev before producing any explanation.
                _ = try await jev.evaluate(
                    utterance: "사용자가 현재 바라보는 사진의 상황 설명을 직접 요청했습니다.",
                    previousUtterance: recentUtterances.last
                )
                try Task.checkCancellation()
                guard generation == self.generation else { return }
                jevReady = true
                let text = try await gemini.describePhoto(
                    jpegData: photo.jpegData,
                    recentContext: recentUtterances.suffix(2).joined(separator: " ")
                )
                try Task.checkCancellation()
                guard generation == self.generation else { return }
                let line = TranscriptLine(timestamp: Date(), text: "meeting.photo.title".localized,
                    whisper: WhisperEvent(term: "", text: text, confidence: 1, state: .speaking))
                lines.append(line)
                if lines.count > 200 { lines.removeFirst(lines.count - 200) }
                transcription.pause()
                isPausingForWhisper = runState == .listening
                isSpeakingWhisper = true
                sawWhisperPlayback = false
                if let requestID = tts.enqueue(text, volume: 0.35) {
                    activeWhisperRequestID = requestID
                } else {
                    finishWhisper(state: .failed)
                    photoError = "meeting.photo.voiceFailed".localized
                }
            } catch {
                guard generation == self.generation, !Task.isCancelled else { return }
                if temporaryStream { await streamViewModel.stopSession() }
                guard generation == self.generation else { return }
                if let jevError = error as? JevClientError {
                    failStopJev(code: jevError.code, message: jevError.message)
                } else {
                    photoError = "meeting.photo.failed".localized
                    UINotificationFeedbackGenerator().notificationOccurred(.error)
                }
            }
        }
    }

    private func handlePlaybackStateChange(_ state: TTSService.PlaybackState) {
        switch state {
        case .queued(let requestID), .speaking(let requestID):
            guard requestID == activeWhisperRequestID else { return }
            sawWhisperPlayback = true
            isSpeakingWhisper = true
        case .failed(let requestID):
            guard requestID == activeWhisperRequestID else { return }
            finishWhisper(state: .failed)
        case .idle:
            // enqueue 내부 stop()이 보내는 .idle은 무시하고
            // 실제 재생(queued/speaking) 뒤의 .idle에서만 재개한다.
            guard sawWhisperPlayback else { return }
            finishWhisper(state: .spoken)
        }
    }

    private func finishWhisper(state: WhisperEvent.State) {
        for index in lines.indices where lines[index].whisper?.state == .speaking {
            lines[index].whisper?.state = state
        }
        isSpeakingWhisper = false
        activeWhisperRequestID = nil
        sawWhisperPlayback = false

        if isPausingForWhisper {
            isPausingForWhisper = false
            if runState == .listening {
                transcription.resume()
            }
        }
    }

    private func updateLine(_ id: UUID, _ update: (inout TranscriptLine) -> Void) {
        guard let index = lines.firstIndex(where: { $0.id == id }) else { return }
        update(&lines[index])
    }

    private func updateFactCard(_ id: UUID, _ update: (inout FactCard) -> Void) {
        guard let index = factCards.firstIndex(where: { $0.id == id }) else { return }
        update(&factCards[index])
    }

    private func failStopJev(code: String, message: String) {
        stop()
        jevReady = false
        failure = .jev(code: code, message: message)
        print("[Meeting][ERROR] 판단 서비스 중지 code=\(code)")
    }

    private func failMicrophone(_ message: String) {
        stop()
        failure = .microphone(message)
    }
}
