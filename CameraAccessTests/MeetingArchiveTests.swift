import XCTest
import AVFoundation
@testable import CameraAccess

@MainActor
final class MeetingArchiveTests: XCTestCase {
    private var tempRoot: URL!
    private var archive: MeetingArchiveService!

    override func setUp() async throws {
        try await super.setUp()
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeetingArchiveTests-\(UUID().uuidString)", isDirectory: true)
        archive = MeetingArchiveService(rootURL: tempRoot)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempRoot)
        tempRoot = nil
        archive = nil
        try await super.tearDown()
    }

    func testCheckpointPreservesOffscreenLinesAndUpdatesRevisions() {
        let first = ArchivedMeetingLine(offset: 0, text: "첫 문장")
        let second = ArchivedMeetingLine(offset: 1, text: "임시 문장")
        var meeting = ArchivedMeeting(id: UUID(), startedAt: Date(timeIntervalSince1970: 100),
            lines: [first, second], mode: .realtime)
        archive.checkpoint(meeting)
        meeting.lines = [ArchivedMeetingLine(id: second.id, offset: 1, text: "확정 문장")]
        archive.checkpoint(meeting)
        let saved = archive.loadAll().first
        XCTAssertEqual(saved?.lines.map(\.text), ["첫 문장", "확정 문장"])
        XCTAssertNil(saved?.endedAt)
    }

    func testLongArchiveSurvivesNewServiceInstance() {
        let id = UUID()
        let start = Date(timeIntervalSince1970: 100)
        let allLines = (0..<350).map { ArchivedMeetingLine(offset: Double($0), text: "문장 \($0)") }
        XCTAssertTrue(archive.checkpoint(ArchivedMeeting(id: id, startedAt: start,
            lines: Array(allLines.prefix(200)), mode: .realtime)))
        XCTAssertTrue(archive.checkpoint(ArchivedMeeting(id: id, startedAt: start,
            lines: Array(allLines.suffix(200)), mode: .realtime)))
        let reopened = MeetingArchiveService(rootURL: tempRoot)
        XCTAssertEqual(reopened.loadAll().first?.lines, allLines)
    }

    func testSpeakerSegmentsSurviveCheckpointWindowReplacement() {
        let first = ArchivedSpeakerTurn(offset: 1, text: "첫 발언", speaker: "chunk1:spk_1", role: "other")
        let second = ArchivedSpeakerTurn(offset: 31, text: "다음 발언", speaker: "chunk2:spk_1", role: "unknown")
        var meeting = ArchivedMeeting(id: UUID(), startedAt: Date(), lines: [], mode: .realtime,
            speakerTurns: [first])
        XCTAssertTrue(archive.checkpoint(meeting))
        meeting.speakerTurns = [second]
        XCTAssertTrue(archive.checkpoint(meeting))
        XCTAssertEqual(archive.loadAll().first?.speakerTurns, [first, second])
    }

    func testLegacyJSONMigratesWithoutLosingOffscreenTranscript() throws {
        let original = sampleMeeting()
        try archive.prepare(id: original.id)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(original).write(to: archive.sessionURL(id: original.id).appendingPathComponent("transcript.json"))
        var checkpoint = original
        checkpoint.lines = [ArchivedMeetingLine(offset: 160, text: "추가 문장")]
        XCTAssertTrue(archive.checkpoint(checkpoint))
        XCTAssertEqual(archive.loadAll().first?.lines.count, 3)
        XCTAssertTrue(FileManager.default.fileExists(atPath:
            archive.sessionURL(id: original.id).appendingPathComponent("transcript.json").path))
    }

    func testProcessingProgressAndSourcesPersistWithoutExecutingProcessing() {
        var meeting = sampleMeeting()
        meeting.mode = .passive
        meeting.processingState = .failed
        meeting.transcribedUnits = ["audio-000000.caf:0"]
        meeting.analyzedLines = [meeting.lines[0].id]
        meeting.lines[0].sourceURLs = ["https://example.com/evidence"]
        XCTAssertTrue(archive.save(meeting))
        let reopened = MeetingArchiveService(rootURL: tempRoot)
        XCTAssertEqual(reopened.loadAll().first, meeting)
        XCTAssertFalse(MeetingArchiveService.isProcessing)
    }

    func testPassiveSessionWithoutTranscriptIsPreserved() {
        let meeting = ArchivedMeeting(id: UUID(), startedAt: Date(timeIntervalSince1970: 100),
            lines: [], mode: .passive, processingState: .unprocessed)
        archive.checkpoint(meeting)
        XCTAssertEqual(archive.loadAll().first, meeting)
    }

    func testRecoveryDoesNotTouchActiveRecording() {
        let meeting = ArchivedMeeting(id: UUID(), startedAt: Date(), lines: [],
            mode: .passive, processingState: .unprocessed)
        archive.save(meeting)
        MeetingArchiveService.recordingID = meeting.id
        defer { MeetingArchiveService.recordingID = nil }
        archive.recoverInterruptedRecordings()
        archive.delete(id: meeting.id)
        XCTAssertEqual(archive.loadAll().first, meeting)
    }

    func testInterruptedPassiveRecordingRecoversWithoutProcessing() {
        let meeting = ArchivedMeeting(id: UUID(), startedAt: Date(), lines: [],
            mode: .passive, processingState: .unprocessed)
        archive.save(meeting)
        archive.recoverInterruptedRecordings()
        let recovered = archive.loadAll().first
        XCTAssertEqual(recovered?.recovered, true)
        XCTAssertNotNil(recovered?.endedAt)
        XCTAssertEqual(recovered?.processingState, .unprocessed)
    }

    func testAudioChunksRotateAndRemainDiscoverable() throws {
        let id = UUID()
        try archive.prepare(id: id)
        let box = MeetingAudioFileBox()
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16000))
        buffer.frameLength = 16000
        let samples = try XCTUnwrap(buffer.floatChannelData)[0]
        for index in 0..<16000 { samples[index] = 0 }
        try box.configure(destination: archive.audioURL(id: id), format: format)
        for _ in 0..<31 { XCTAssertTrue(box.write(buffer)) }
        box.clear()
        let urls = archive.audioFileURLs(id: id)
        XCTAssertEqual(urls.count, 2)
        XCTAssertEqual(try AVAudioFile(forReading: urls[0]).length, 480000)
        XCTAssertEqual(try AVAudioFile(forReading: urls[1]).length, 16000)
    }

    private func sampleMeeting() -> ArchivedMeeting {
        ArchivedMeeting(
            id: UUID(),
            startedAt: Date(timeIntervalSince1970: 1_790_000_000),
            endedAt: Date(timeIntervalSince1970: 1_790_000_600),
            lines: [
                ArchivedMeetingLine(
                    offset: 83,
                    text: "이번 분기 EBITDA 기준을 맞춰야 합니다.",
                    term: "EBITDA",
                    whisper: "본업 수익성을 보는 지표예요."
                ),
                ArchivedMeetingLine(offset: 150, text: "다음 안건으로 넘어가죠.", term: nil, whisper: nil)
            ],
            catches: [
                ArchivedMeetingCatch(
                    kind: "unsupported",
                    quote: "다들 그렇게 해요",
                    point: "근거 없이 다수에 기댄 주장",
                    ask: "어떤 사례가 있나요?",
                    confidence: 0.8,
                    offset: 100,
                    speakerKnown: true
                )
            ]
        )
    }

    func testSaveAndLoadRoundTripKeepsLines() {
        let meeting = sampleMeeting()
        archive.save(meeting)

        let loaded = archive.loadAll()
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded.first?.id, meeting.id)
        XCTAssertEqual(loaded.first?.lines.count, 2)
        XCTAssertEqual(loaded.first?.lines.first?.text, meeting.lines[0].text)
        XCTAssertEqual(loaded.first?.lines.first?.term, "EBITDA")
        XCTAssertEqual(loaded.first?.lines.first?.whisper, "본업 수익성을 보는 지표예요.")
        XCTAssertEqual(loaded.first?.catches?.count, 1)
        XCTAssertEqual(loaded.first?.catches?.first?.kind, "unsupported")
        XCTAssertEqual(loaded.first?.catches?.first?.ask, "어떤 사례가 있나요?")
    }

    func testEmptyMeetingIsNotSaved() {
        let meeting = ArchivedMeeting(id: UUID(), startedAt: Date(), endedAt: Date(), lines: [])
        archive.save(meeting)

        XCTAssertTrue(archive.loadAll().isEmpty)
    }

    func testDeleteRemovesSession() {
        let meeting = sampleMeeting()
        archive.save(meeting)
        archive.delete(id: meeting.id)

        XCTAssertTrue(archive.loadAll().isEmpty)
    }

    func testAudioURLIsNilUntilRecordingExists() {
        let meeting = sampleMeeting()
        archive.save(meeting)

        XCTAssertNil(archive.audioFileURL(id: meeting.id))
    }

    func testExportTextIncludesTimestampsWhisperAndCounts() {
        let meeting = sampleMeeting()
        let text = MeetingArchiveService.exportText(meeting)

        XCTAssertTrue(text.contains("TurboMeta 대화 녹취록"))
        XCTAssertTrue(text.contains("발화 2건"))
        XCTAssertTrue(text.contains("잡아낸 것 1건"))
        XCTAssertTrue(text.contains("인용: 다들 그렇게 해요"))
        XCTAssertTrue(text.contains("[00:01:23] 이번 분기 EBITDA 기준을 맞춰야 합니다."))
        XCTAssertTrue(text.contains("└ 귓속말: EBITDA — 본업 수익성을 보는 지표예요."))
        XCTAssertTrue(text.contains("[00:02:30] 다음 안건으로 넘어가죠."))
    }

    func testOffsetTextFormatsHoursMinutesSeconds() {
        XCTAssertEqual(MeetingArchiveService.offsetText(0), "00:00:00")
        XCTAssertEqual(MeetingArchiveService.offsetText(83), "00:01:23")
        XCTAssertEqual(MeetingArchiveService.offsetText(3671), "01:01:11")
        XCTAssertEqual(MeetingArchiveService.offsetText(-5), "00:00:00")
    }
}
