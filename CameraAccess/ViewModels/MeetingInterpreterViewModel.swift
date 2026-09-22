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

    private let transcription = MeetingTranscriptionService()
    private let jev = JevClient.shared
    private let gemini = MeetingGeminiService()
    private let tts = TTSService.shared
    private var lastWhisperAt: Date?
    private var isPausingForWhisper = false
    private var playbackCancellable: AnyCancellable?
    private var recentUtterances: [String] = []

    init() {
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
        guard runState == .idle else { return }
        failure = nil

        guard JevClient.storedAPIKey != nil else {
            failure = .jev(
                code: JevClientError.missingAPIKey.code,
                message: "Jev API 키가 설정되지 않았습니다. 설정에서 TypeSafe Jev API Key를 등록하세요."
            )
            return
        }

        Task {
            do {
                try await transcription.start()
                inputRouteName = transcription.inputRouteName
                runState = .listening
            } catch {
                let message = (error as? MeetingTranscriptionError)?.message
                    ?? error.localizedDescription
                failMicrophone(message)
            }
        }
    }

    func stop() {
        transcription.stop()
        tts.stop()
        runState = .idle
        isSpeakingWhisper = false
        isPausingForWhisper = false
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
        let previous = recentUtterances.count > 1
            ? recentUtterances[recentUtterances.count - 2]
            : nil

        do {
            let decision = try await jev.evaluate(
                utterance: text,
                previousUtterance: previous
            )
            jevReady = true

            if decision.lane == .factcheck {
                beginFactCheck(claim: text)
            }

            let now = Date()
            if decision.needsExplanation,
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
            failStopJev(code: error.code, message: error.message)
        } catch {
            failStopJev(
                code: JevClientError.invalidResponse.code,
                message: JevClientError.invalidResponse.message
            )
        }
    }

    private func beginFactCheck(claim: String) {
        let card = FactCard(claim: claim)
        factCards.insert(card, at: 0)
        if factCards.count > 20 {
            factCards.removeLast(factCards.count - 20)
        }

        let cardID = card.id
        Task {
            do {
                let result = try await gemini.factCheck(claim: claim)
                updateFactCard(cardID) {
                    $0.state = .done
                    $0.summary = result.summary
                    $0.links = result.links
                }
            } catch {
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
        let context = recentUtterances.count > 1
            ? recentUtterances[recentUtterances.count - 2]
            : ""

        do {
            let explanation = try await gemini.explain(
                utterance: utterance,
                recentContext: context
            )
            updateLine(lineID) {
                $0.whisper = WhisperEvent(
                    text: explanation,
                    confidence: confidence,
                    state: .speaking
                )
            }
            transcription.pause()
            isPausingForWhisper = true
            isSpeakingWhisper = true
            if tts.enqueue(explanation, volume: 0.35) == nil {
                finishWhisper(state: .failed)
            }
        } catch {
            updateLine(lineID) {
                $0.whisper = WhisperEvent(
                    text: "",
                    confidence: confidence,
                    state: .failed
                )
            }
        }
    }

    private func handlePlaybackStateChange(_ state: TTSService.PlaybackState) {
        switch state {
        case .queued, .speaking:
            isSpeakingWhisper = true
        case .idle, .failed:
            guard isPausingForWhisper else { return }
            finishWhisper(state: .spoken)
        }
    }

    private func finishWhisper(state: WhisperEvent.State) {
        for index in lines.indices where lines[index].whisper?.state == .speaking {
            lines[index].whisper?.state = state
        }
        isSpeakingWhisper = false

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
