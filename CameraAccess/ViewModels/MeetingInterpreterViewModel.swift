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
    /// Jev confidence는 보정된 확률이 아니라 상대적 강도이므로 0.6 이상이면 개입한다.
    static let whisperConfidenceThreshold = 0.6
    /// 사전(lexicon) 적중 시 낮춘 문턱. 확정이 아니라 가중치다.
    static let lexiconConfidenceThreshold = 0.3
    /// Gemini 429 이후 설명 생성을 쉬는 시간(초).
    static let explainQuotaPause: TimeInterval = 120
    /// Gemini 429 이후 근거 검색을 쉬는 시간(초).
    static let factQuotaPause: TimeInterval = 300

    /// 자주 나오는 비즈니스·개발 용어와 약어. 전부 소문자로 저장한다.
    static let lexiconTerms: Set<String> = [
        // 비즈니스/재무/전략
        "ebitda", "roi", "roas", "kpi", "okr", "mrr", "arr", "cac", "ltv", "npv", "irr",
        "dcf", "gmv", "aov", "ctr", "cpa", "cpc", "ttm", "qoq", "yoy", "mom", "pnl",
        "crm", "erp", "b2b", "b2c", "sla", "sow", "rfp", "nda", "msa", "po", "csat", "nps",
        "churn", "upsell", "seo", "sem", "ugc", "kyc", "aml",
        // 개발/인프라/데이터/보안
        "api", "sdk", "ide", "cli", "gui", "ux", "ui", "qa", "ci", "cd", "vcs", "pr", "mr",
        "db", "sql", "nosql", "orm", "mvc", "mvvm", "oop", "tdd", "bdd", "ddd", "sdlc",
        "aws", "gcp", "s3", "ec2", "ecs", "eks", "vpc", "iam", "cdn", "dns", "tls", "ssl",
        "http", "https", "rest", "grpc", "json", "xml", "yaml", "csv", "k8s", "pod",
        "docker", "kubernetes", "helm", "terraform", "redis", "kafka", "nginx", "oauth", "jwt", "sso", "mfa",
        "xss", "csrf", "ssr", "spa", "pwa", "slo", "mttr", "mtbf", "rto", "rpo", "vpn", "ssh",
        "tcp", "udp", "iot", "ai", "ml", "llm", "nlp", "rag", "gpu", "cpu", "iops", "git",
        "repo", "prod", "dev"
    ]

    /// 전사 토큰 중 사전 용어가 있으면 참. 확정 판정이 아니라 문턱 완화 근거다.
    /// 한국어 전사는 "EBITDA가"처럼 조사가 바로 붙으므로 ASCII 영문·숫자 연속 구간만 토큰으로 뗀다.
    nonisolated static func lexiconHit(in text: String) -> Bool {
        var token = ""
        func matches(_ candidate: String) -> Bool {
            candidate.count >= 2 && lexiconTerms.contains(candidate.lowercased())
        }
        for scalar in text.unicodeScalars {
            if scalar.isASCII, CharacterSet.alphanumerics.contains(scalar) {
                token.unicodeScalars.append(scalar)
            } else {
                if matches(token) { return true }
                token = ""
            }
        }
        return matches(token)
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
        var category: String = ""
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
        let lineID: UUID
        var state: FactState = .pending
        var summary: String?
        var links: [MeetingFactLink] = []
    }

    struct DetailBubble: Identifiable, Equatable {
        enum State: Equatable {
            case loading
            case ready(message: String, links: [MeetingFactLink])
            case failed
        }

        let id: UUID
        let query: String
        var state: State
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
    @Published private(set) var detailBubble: DetailBubble?

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
    private let watchBridge = WatchBridgeService.shared
    private var lastWatchSyncAt = Date.distantPast
    private let archive = MeetingArchiveService()
    private var archiveID: UUID?
    private var archiveStartedAt: Date?
    private var latestStable = ""
    private var explainPausedUntil: Date?
    private var factPausedUntil: Date?
    private var detailTask: Task<Void, Never>?

    private var isExplainPaused: Bool {
        Date() < (explainPausedUntil ?? .distantPast)
    }

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
            self.latestStable = text
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
        watchBridge.activate()
    }

    func start() {
        guard runState == .idle, !isStarting, !isStopping, !isDescribingPhoto, !isSpeakingWhisper else { return }
        failure = nil
        analyzedTexts.removeAll()
        spokenTerms.removeAll()
        checkedClaims.removeAll()
        explainPausedUntil = nil
        factPausedUntil = nil
        latestStable = ""
        detailBubble = nil

        guard JevClient.storedAPIKey != nil else {
            failure = .jev(
                code: JevClientError.missingAPIKey.code,
                message: "Jev API 키가 설정되지 않았습니다. 설정에서 TypeSafe Jev API Key를 등록하세요."
            )
            return
        }

        isStarting = true
        let archiveID = UUID()
        self.archiveID = archiveID
        archiveStartedAt = Date()
        do {
            try archive.prepare(id: archiveID)
            transcription.recordingDestination = archive.audioURL(id: archiveID)
        } catch {
            transcription.recordingDestination = nil
            DeveloperConsole.shared.log(.warning, category: "MeetingArchive", "prepare failed code=\((error as NSError).code)")
        }
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
                syncWatch(force: true)
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
        if let archiveID, let archiveStartedAt {
            let archivedLines = lines.map { line in
                ArchivedMeetingLine(
                    offset: line.timestamp.timeIntervalSince(archiveStartedAt),
                    text: line.text,
                    term: line.whisper?.term.isEmpty == false ? line.whisper?.term : nil,
                    whisper: line.whisper?.text.isEmpty == false ? line.whisper?.text : nil,
                    category: line.whisper?.category.isEmpty == false ? line.whisper?.category : nil
                )
            }
            archive.save(ArchivedMeeting(
                id: archiveID,
                startedAt: archiveStartedAt,
                endedAt: Date(),
                lines: archivedLines
            ))
        }
        archiveID = nil
        archiveStartedAt = nil
        transcription.recordingDestination = nil
        detailTask?.cancel()
        detailTask = nil
        detailBubble = nil
        syncWatch(force: true)
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
        syncWatch()
    }

    private func queueAnalysis(_ text: String, lineID: UUID) {
        guard runState == .listening, text.count >= 2, !analyzedTexts.contains(text) else { return }
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
            guard generation == self.generation, runState == .listening else {
                DeveloperConsole.shared.log(.warning, category: "MeetingWhisper", "discarded stopped=true stage=decision")
                return
            }
            jevReady = true
            DeveloperConsole.shared.log(.info, category: "MeetingDecision", "explain=\(decision.needsExplanation) confidence=\(decision.explanationConfidence) lane=\(decision.lane.rawValue)")

            if decision.lane == .factcheck {
                beginFactCheck(claim: text, lineID: lineID)
            }

            let lexiconHit = MeetingPolicy.lexiconHit(in: text)
            let threshold = lexiconHit
                ? MeetingPolicy.lexiconConfidenceThreshold
                : MeetingPolicy.whisperConfidenceThreshold
            if !isDescribingPhoto, !isSpeakingWhisper, !isPreparingWhisper,
               !isExplainPaused,
               decision.needsExplanation,
               decision.category != "none",
               decision.explanationConfidence >= threshold {
                await speakExplanation(
                    for: text,
                    lineID: lineID,
                    confidence: decision.explanationConfidence
                )
            } else {
                DeveloperConsole.shared.log(.info, category: "MeetingDecision", "skipped busy=\(isDescribingPhoto || isSpeakingWhisper || isPreparingWhisper) quotaPaused=\(isExplainPaused) requested=\(decision.needsExplanation) category=\(decision.category) confidence=\(decision.explanationConfidence) lexicon=\(lexiconHit) threshold=\(threshold)")
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

    private func beginFactCheck(claim: String, lineID: UUID) {
        if Date() < (factPausedUntil ?? .distantPast) {
            DeveloperConsole.shared.log(.info, category: "MeetingDecision", "factcheck skipped quotaPaused=true")
            return
        }
        guard checkedClaims.insert(claim.lowercased()).inserted else { return }
        let generation = self.generation
        let card = FactCard(claim: claim, lineID: lineID)
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
            while Date() < (factPausedUntil ?? .distantPast) {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                guard generation == self.generation, !Task.isCancelled else { return }
            }
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
                if let geminiError = error as? MeetingGeminiError,
                   case .http(429) = geminiError {
                    factPausedUntil = Date().addingTimeInterval(MeetingPolicy.factQuotaPause)
                    DeveloperConsole.shared.log(.warning, category: "MeetingDecision", "factcheck quota paused seconds=\(Int(MeetingPolicy.factQuotaPause))")
                    syncWatch(force: true)
                }
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
            let explanation = try await requestExplanation(utterance: utterance, context: context)
            guard generation == self.generation, runState == .listening,
                  !isDescribingPhoto, !isSpeakingWhisper else {
                DeveloperConsole.shared.log(.warning, category: "MeetingWhisper", "discarded stopped=true stage=explanation")
                return
            }
            guard !explanation.text.isEmpty else {
                DeveloperConsole.shared.log(.info, category: "MeetingWhisper", "skipped noTerm=true")
                return
            }
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
                    state: .speaking,
                    category: explanation.category
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

    /// 설명 요청: 일시 실패(503·타임아웃)는 최신 안정 문장으로 1회 재시도하고,
    /// 429는 재시도 없이 즉시 실패 처리한 뒤 일정 시간 설명 생성을 쉰다.
    private func requestExplanation(utterance: String, context: String) async throws -> MeetingExplanation {
        do {
            return try await gemini.explain(
                utterance: utterance,
                recentContext: context,
                sceneContext: sceneSummary,
                explainedTerms: Array(spokenTerms.sorted().prefix(100))
            )
        } catch {
            if let geminiError = error as? MeetingGeminiError,
               case .http(429) = geminiError {
                explainPausedUntil = Date().addingTimeInterval(MeetingPolicy.explainQuotaPause)
                DeveloperConsole.shared.log(.warning, category: "MeetingWhisper", "quota paused seconds=\(Int(MeetingPolicy.explainQuotaPause))")
                syncWatch(force: true)
                throw error
            }
            DeveloperConsole.shared.log(.warning, category: "MeetingWhisper", "retry once domain=\((error as NSError).domain) code=\((error as NSError).code)")
            let retryText = latestStable.isEmpty ? utterance : latestStable
            return try await gemini.explain(
                utterance: retryText,
                recentContext: context,
                sceneContext: sceneSummary,
                explainedTerms: Array(spokenTerms.sorted().prefix(100))
            )
        }
    }

    /// 전사 줄을 터치하면 보관된 설명·근거 링크를 말풍선으로 보여주고 읽어 준다.
    /// 보관된 설명이 없으면 사용자가 직접 요청한 것이므로 Jev 게이트 없이 생성한다.
    func handleLineTap(_ lineID: UUID) {
        guard failure == nil, !isStopping,
              let line = lines.first(where: { $0.id == lineID }) else { return }
        closeDetail()

        if let whisper = line.whisper, !whisper.text.isEmpty {
            showDetail(line: line, message: whisper.text, links: factLinks(for: lineID))
            return
        }
        if let card = factCards.first(where: { $0.lineID == lineID }),
           card.state == .done, let summary = card.summary {
            showDetail(line: line, message: summary, links: card.links)
            return
        }

        detailBubble = DetailBubble(id: lineID, query: line.text, state: .loading)
        let generation = self.generation
        detailTask = Task {
            do {
                let explanation = try await requestExplanation(
                    utterance: line.text,
                    context: previousContext(for: lineID) ?? ""
                )
                guard generation == self.generation, detailBubble?.id == lineID else { return }
                updateLine(lineID) { target in
                    if target.whisper == nil || target.whisper?.text.isEmpty == true {
                        target.whisper = WhisperEvent(
                            term: explanation.term,
                            text: explanation.text,
                            confidence: 1,
                            state: .spoken
                        )
                    }
                }
                detailBubble?.state = .ready(message: explanation.text, links: factLinks(for: lineID))
                updateLine(lineID) { target in
                    target.whisper?.category = explanation.category
                }
                speakDetail(explanation.text)
            } catch {
                guard generation == self.generation, detailBubble?.id == lineID else { return }
                DeveloperConsole.shared.log(.warning, category: "MeetingWhisper", "detail failed domain=\((error as NSError).domain) code=\((error as NSError).code)")
                detailBubble?.state = .failed
            }
        }
    }

    func closeDetail() {
        detailTask?.cancel()
        detailTask = nil
        detailBubble = nil
    }

    private func factLinks(for lineID: UUID) -> [MeetingFactLink] {
        factCards.first(where: { $0.lineID == lineID })?.links ?? []
    }

    private func showDetail(line: TranscriptLine, message: String, links: [MeetingFactLink]) {
        detailBubble = DetailBubble(id: line.id, query: line.text, state: .ready(message: message, links: links))
        speakDetail(message)
    }

    private func speakDetail(_ text: String) {
        guard let requestID = tts.enqueue(
            text,
            volume: 0.35,
            preserveRecordingSession: runState == .listening
        ) else { return }
        activeWhisperRequestID = requestID
        sawWhisperPlayback = true
        isSpeakingWhisper = true
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
        syncWatch(force: true)
        print("[Meeting][ERROR] 판단 서비스 중지 code=\(code)")
    }

    private func failMicrophone(_ message: String) {
        stop()
        failure = .microphone(message)
        syncWatch(force: true)
    }

    private func syncWatch(force: Bool = false) {
        let now = Date()
        guard force || now.timeIntervalSince(lastWatchSyncAt) >= 2 else { return }
        lastWatchSyncAt = now
        watchBridge.update(
            state: runState == .listening ? "listening" : "idle",
            route: inputRouteName,
            startedAt: archiveStartedAt,
            latest: lines.last?.text ?? "",
            recent: Array(lines.suffix(5).map(\.text)),
            whisperCount: lines.filter { $0.whisper?.text.isEmpty == false }.count,
            error: failureText,
            quotaPaused: isExplainPaused || Date() < (factPausedUntil ?? .distantPast)
        )
    }

    private var failureText: String {
        switch failure {
        case .jev(let code, _): return code
        case .microphone: return "E-MIC-503"
        case nil: return ""
        }
    }
}
