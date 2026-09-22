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
        var text: String
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
    private var activeWhisperRequestID: UUID?
    private var sawWhisperPlayback = false
    private var playbackCancellable: AnyCancellable?
    private var recentUtterances: [String] = []
    private var generation = UUID()
    private var startTask: Task<Void, Never>?
    private var photoTask: Task<Void, Never>?
    private var isPreparingWhisper = false
    private var liveLineID: UUID?
    private var analysisQueue: [(String, UUID)] = []
    private var analysisTask: Task<Void, Never>?
    private var analyzedTexts: [String] = []
    private var spokenTerms = Set<String>()
    private var activeTerm: String?
    private var checkedClaims = Set<String>()
    private var factQueue: [(String, UUID)] = []
    private var factTask: Task<Void, Never>?

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
        transcription.onPartial = { [weak self] text in self?.updateLiveCaption(text) }
        transcription.onStable = { [weak self] text in
            guard let self, let id = self.liveLineID else { return }
            self.queueAnalysis(text, lineID: id)
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
        analyzedTexts.removeAll()
        spokenTerms.removeAll()
        checkedClaims.removeAll()

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
        // Keep the final on-screen revision when stopping, but do not start new AI work.
        liveLineID = nil
        analysisTask?.cancel()
        analysisTask = nil
        analysisQueue.removeAll()
        factTask?.cancel()
        factTask = nil
        factQueue.removeAll()
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
        visualAssist?.isUserRequestActive = false
        activeTerm = nil
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
        activeWhisperRequestID = nil
        sawWhisperPlayback = false
    }

    private func handleUtterance(_ text: String) {
        guard failure == nil, runState == .listening else { return }
        updateLiveCaption(text)
        guard let lineID = liveLineID else { return }
        liveLineID = nil

        recentUtterances.append(text)
        if recentUtterances.count > 6 {
            recentUtterances.removeFirst(recentUtterances.count - 6)
        }

        queueAnalysis(text, lineID: lineID)
    }

    private func updateLiveCaption(_ text: String) {
        guard runState == .listening else { return }
        if let id = liveLineID {
            updateLine(id) { $0.text = text }
        } else {
            let line = TranscriptLine(timestamp: Date(), text: text)
            liveLineID = line.id
            lines.append(line)
            if lines.count > 200 { lines.removeFirst(lines.count - 200) }
        }
    }

    private func queueAnalysis(_ text: String, lineID: UUID) {
        guard runState == .listening, !analyzedTexts.contains(text) else { return }
        // Only the newest revision of an unprocessed live line is useful.
        analysisQueue.removeAll { $0.1 == lineID }
        analysisQueue.append((text, lineID))
        if analysisQueue.count > 6 { analysisQueue.removeFirst() }
        guard analysisTask == nil else { return }
        let generation = self.generation
        analysisTask = Task {
            defer { if generation == self.generation { analysisTask = nil } }
            while !Task.isCancelled, generation == self.generation, !analysisQueue.isEmpty {
                if isDescribingPhoto || isSpeakingWhisper {
                    try? await Task.sleep(nanoseconds: 200_000_000)
                    continue
                }
                let (text, id) = analysisQueue.removeFirst()
                analyzedTexts.append(text)
                if analyzedTexts.count > 100 { analyzedTexts.removeFirst() }
                await processUtterance(text, lineID: id)
            }
        }
    }

    private func processUtterance(_ text: String, lineID: UUID) async {
        guard runState == .listening, failure == nil else { return }
        let generation = self.generation
        let previous = previousContext(for: lineID)

        do {
            let decision = try await jev.evaluate(
                utterance: text,
                previousUtterance: previous
            )
            guard generation == self.generation, runState == .listening else { return }
            jevReady = true
            DeveloperConsole.shared.log(.info, category: "MeetingDecision", "explain=\(decision.needsExplanation) confidence=\(decision.explanationConfidence) lane=\(decision.lane.rawValue)")

            if decision.lane == .factcheck {
                beginFactCheck(claim: text)
            }

            if !isDescribingPhoto, !isSpeakingWhisper, !isPreparingWhisper,
               decision.needsExplanation,
               decision.explanationConfidence >= MeetingPolicy.whisperConfidenceThreshold {
                await speakExplanation(
                    for: text,
                    lineID: lineID,
                    confidence: decision.explanationConfidence
                )
            } else {
                DeveloperConsole.shared.log(.info, category: "MeetingDecision", "skipped busy=\(isDescribingPhoto || isSpeakingWhisper || isPreparingWhisper) requested=\(decision.needsExplanation) threshold=\(MeetingPolicy.whisperConfidenceThreshold)")
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
        guard checkedClaims.insert(claim.lowercased()).inserted else { return }
        let generation = self.generation
        let card = FactCard(claim: claim)
        factCards.insert(card, at: 0)
        if factCards.count > 20 {
            factCards.removeLast(factCards.count - 20)
        }

        factQueue.append((claim, card.id))
        if factQueue.count > 20 { factQueue.removeFirst() }
        guard factTask == nil else { return }
        factTask = Task {
          defer { if generation == self.generation { factTask = nil } }
          while !Task.isCancelled, generation == self.generation, !factQueue.isEmpty {
            let (claim, cardID) = factQueue.removeFirst()
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
    }

    private func speakExplanation(
        for utterance: String,
        lineID: UUID,
        confidence: Double
    ) async {
        let generation = self.generation
        isPreparingWhisper = true
        defer { if generation == self.generation { isPreparingWhisper = false } }
        let context = previousContext(for: lineID) ?? ""

        do {
            let explanation = try await gemini.explain(
                utterance: utterance,
                recentContext: context,
                sceneContext: sceneSummary,
                explainedTerms: Array(spokenTerms.sorted().prefix(100))
            )
            guard generation == self.generation, runState == .listening,
                  !isDescribingPhoto, !isSpeakingWhisper else { return }
            let term = explanation.term.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !term.isEmpty, !spokenTerms.contains(term) else {
                DeveloperConsole.shared.log(.info, category: "MeetingWhisper", "skipped emptyOrRepeatedTerm=true")
                return
            }
            activeTerm = term
            updateLine(lineID) {
                $0.whisper = WhisperEvent(
                    term: explanation.term,
                    text: explanation.text,
                    confidence: confidence,
                    state: .speaking
                )
            }
            isSpeakingWhisper = true
            if let requestID = tts.enqueue(explanation.text, volume: 0.35, preserveRecordingSession: true) {
                activeWhisperRequestID = requestID
            } else {
                activeTerm = nil
                updateLine(lineID) {
                    $0.whisper?.state = .failed
                }
                isSpeakingWhisper = false
            }
        } catch {
            guard generation == self.generation else { return }
            DeveloperConsole.shared.log(.error, category: "MeetingWhisper", "explanation failed domain=\((error as NSError).domain) code=\((error as NSError).code)")
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
        visualAssist?.isUserRequestActive = true
        photoError = nil
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        let generation = self.generation
        photoTask = Task {
            let temporaryStream = runState == .idle || visualAssist == nil
            defer {
                if generation == self.generation {
                    isDescribingPhoto = false
                    visualAssist?.isUserRequestActive = false
                }
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
                isSpeakingWhisper = true
                sawWhisperPlayback = false
                if let requestID = tts.enqueue(text, volume: 0.35, preserveRecordingSession: runState == .listening) {
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
        DeveloperConsole.shared.log(.info, category: "MeetingPlayback", "state=\(state) listening=\(runState == .listening)")
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
        if state == .spoken, let activeTerm { spokenTerms.insert(activeTerm) }
        activeTerm = nil
        for index in lines.indices where lines[index].whisper?.state == .speaking {
            lines[index].whisper?.state = state
        }
        isSpeakingWhisper = false
        activeWhisperRequestID = nil
        sawWhisperPlayback = false

    }

    private func updateLine(_ id: UUID, _ update: (inout TranscriptLine) -> Void) {
        guard let index = lines.firstIndex(where: { $0.id == id }) else { return }
        update(&lines[index])
    }

    private func previousContext(for lineID: UUID) -> String? {
        guard let index = lines.firstIndex(where: { $0.id == lineID }), index > 0 else { return nil }
        return lines[index - 1].text
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
