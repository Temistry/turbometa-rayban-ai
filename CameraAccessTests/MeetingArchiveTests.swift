import XCTest
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
