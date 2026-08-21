import XCTest
@testable import CameraAccess

final class OpenClawDiagnosticReportBuilderTests: XCTestCase {
    func testBuildsPromptFromRequiredMessageAndAllowedAudioLogs() throws {
        let entries = [
            entry("[TTS][AUDIO] 세션 활성 category=playback mode=spokenAudio outputs=[BluetoothA2DPOutput]"),
            entry("[TTS][QUEUE] 요청 접수 request=ABC12345 language=ko-KR quality=2 textLength=42"),
            entry("[TTS][ERROR] iOS 한국어 음성 시작 timeout request=ABC12345", level: .error)
        ]

        let prompt = try OpenClawDiagnosticReportBuilder.makePrompt(
            userMessage: "재생 버튼을 눌렀지만 안경에서 소리가 나지 않았습니다.",
            entries: entries
        )

        XCTAssertTrue(prompt.contains("[사용자 설명]"))
        XCTAssertTrue(prompt.contains("BluetoothA2DPOutput"))
        XCTAssertTrue(prompt.contains("시작 timeout"))
        XCTAssertTrue(prompt.contains("권장 코드 수정 방향"))
        XCTAssertTrue(prompt.contains("직접 수정했다고 주장하지 마세요"))
    }

    func testRejectsEmptyUserMessageAndNoRelevantLogs() {
        XCTAssertThrowsError(
            try OpenClawDiagnosticReportBuilder.makePrompt(
                userMessage: "  ",
                entries: [entry("[TTS][ERROR] failed")]
            )
        ) { error in
            XCTAssertEqual(error as? OpenClawDiagnosticReportBuilder.BuildError, .emptyUserMessage)
        }

        XCTAssertThrowsError(
            try OpenClawDiagnosticReportBuilder.makePrompt(
                userMessage: "음성이 나오지 않습니다.",
                entries: [entry("[Network][INFO] unrelated")]
            )
        ) { error in
            XCTAssertEqual(error as? OpenClawDiagnosticReportBuilder.BuildError, .noRelevantLogs)
        }
    }

    func testExcludesUnrelatedAndSensitiveDiagnosticData() throws {
        let secret = "sk-1234567890SECRET"
        let entries = [
            entry("[TTS][ERROR] AudioSession 설정 실패 domain=NSOSStatusErrorDomain code=-50 description=\(secret)"),
            entry("[Galvis][STT] transcript=사용자가 말한 민감한 원문"),
            entry("[MetricKit][ERROR] stack=private-stack"),
            entry("[OpenClaw][INFO] chat response 원문")
        ]

        let prompt = try OpenClawDiagnosticReportBuilder.makePrompt(
            userMessage: "token=abc123 https://example.com/path?token=secret 192.168.1.20",
            entries: entries
        )

        XCTAssertFalse(prompt.contains(secret))
        XCTAssertFalse(prompt.contains("민감한 원문"))
        XCTAssertFalse(prompt.contains("private-stack"))
        XCTAssertFalse(prompt.contains("chat response 원문"))
        XCTAssertFalse(prompt.contains("token=abc123"))
    }

    func testRemovesFullUUIDIPAndURLFromAllowedLog() throws {
        let entries = [
            entry(
                "[TTS][ERROR] request=123e4567-e89b-12d3-a456-426614174000 "
                + "host=10.1.2.3 url=https://example.com/private code=-1"
            )
        ]

        let prompt = try OpenClawDiagnosticReportBuilder.makePrompt(
            userMessage: "재생 실패",
            entries: entries
        )

        XCTAssertFalse(prompt.contains("123e4567-e89b-12d3-a456-426614174000"))
        XCTAssertFalse(prompt.contains("10.1.2.3"))
        XCTAssertFalse(prompt.contains("https://example.com/private"))
        XCTAssertTrue(prompt.contains("<식별정보 숨김>"))
    }

    func testRemovesHardwareIdentifiersFromAllowedLog() throws {
        let entries = [
            entry(
                "[TTS][ERROR] route=BluetoothA2DPOutput "
                + "mac=80:AA:1C:77:8F:A4 "
                + "device=082A06F3-E05A-43DD-9584-75A56720D064 code=-50"
            )
        ]

        let prompt = try OpenClawDiagnosticReportBuilder.makePrompt(
            userMessage: "재생 실패",
            entries: entries
        )

        XCTAssertFalse(prompt.contains("80:AA:1C:77:8F:A4"))
        XCTAssertFalse(prompt.contains("082A06F3-E05A-43DD-9584-75A56720D064"))
        XCTAssertTrue(prompt.contains("BluetoothA2DPOutput"))
        XCTAssertTrue(prompt.contains("code=-50"))
    }

    func testBoundsUserMessageAndLogCount() throws {
        let entries = (0..<200).map { index in
            entry("[TTS][INFO] event=\(index) textLength=10")
        }
        let prompt = try OpenClawDiagnosticReportBuilder.makePrompt(
            userMessage: String(repeating: "가", count: 2_000),
            entries: entries
        )

        XCTAssertLessThanOrEqual(
            prompt.count,
            OpenClawDiagnosticReportBuilder.maximumReportLength + 30
        )
        XCTAssertFalse(prompt.contains("event=0"))
        XCTAssertTrue(prompt.contains("event=199"))
    }

    private func entry(
        _ message: String,
        level: DeveloperLogLevel = .info
    ) -> DeveloperLogEntry {
        DeveloperLogEntry(timestamp: Date(), level: level, message: message)
    }
}
