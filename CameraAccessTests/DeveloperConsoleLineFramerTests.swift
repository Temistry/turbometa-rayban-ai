/*
 * Line-framing regression coverage for the TestFlight diagnostics console's stdout/stderr
 * capture pipeline. `DeveloperConsoleLineFramer` is the pure buffering core extracted from
 * `DeveloperConsole` so these rules can be verified without touching file handles or pipes.
 */

import XCTest

@testable import CameraAccess

final class DeveloperConsoleLineFramerTests: XCTestCase {
    func testSingleChunkWithTrailingNewlineEmitsOneLine() {
        var framer = DeveloperConsoleLineFramer()
        let lines = framer.append("[TTS][INFO] ready\n")

        XCTAssertEqual(lines, ["[TTS][INFO] ready"])
        XCTAssertFalse(framer.hasPendingText)
    }

    func testChunkWithoutNewlineIsBufferedNotEmitted() {
        var framer = DeveloperConsoleLineFramer()
        let lines = framer.append("processing item 3")

        XCTAssertTrue(lines.isEmpty, "부분 라인은 개행 전까지 즉시 방출되면 안 됨")
        XCTAssertTrue(framer.hasPendingText)
        XCTAssertEqual(framer.pendingText, "processing item 3")
    }

    func testPartialLineIsOnlyCompletedByItsOwnContinuation() {
        // Regression for the bug this task fixes: two unrelated writers must never be joined
        // into a single garbled entry just because the first one didn't end in a newline.
        var framer = DeveloperConsoleLineFramer()

        let firstBatch = framer.append("processing item 3")
        XCTAssertTrue(firstBatch.isEmpty)

        let secondBatch = framer.append(" of 10\n")
        XCTAssertEqual(secondBatch, ["processing item 3 of 10"])
        XCTAssertFalse(framer.hasPendingText)
    }

    func testMultipleLinesInOneChunkAreAllEmittedInOrder() {
        var framer = DeveloperConsoleLineFramer()
        let lines = framer.append("[A][INFO] one\n[B][INFO] two\n[C][INFO] three\n")

        XCTAssertEqual(lines, ["[A][INFO] one", "[B][INFO] two", "[C][INFO] three"])
        XCTAssertFalse(framer.hasPendingText)
    }

    func testTrailingFragmentAfterCompleteLinesStaysBuffered() {
        var framer = DeveloperConsoleLineFramer()
        let lines = framer.append("[A][INFO] complete\nstill writing")

        XCTAssertEqual(lines, ["[A][INFO] complete"])
        XCTAssertEqual(framer.pendingText, "still writing")
    }

    func testOversizedPendingFragmentIsForceFlushedToBoundMemory() {
        var framer = DeveloperConsoleLineFramer(maximumPendingBytes: 16)
        let lines = framer.append("this fragment has no newline and exceeds the cap")

        XCTAssertEqual(lines.count, 1, "최대 버퍼 크기를 넘으면 개행 없이도 강제로 방출되어야 함")
        XCTAssertFalse(framer.hasPendingText)
    }

    func testFlushPendingReturnsAndClearsStalledFragmentOnly() {
        var framer = DeveloperConsoleLineFramer()
        _ = framer.append("stalled fragment with no terminator")

        let flushed = framer.flushPending()

        XCTAssertEqual(flushed, "stalled fragment with no terminator")
        XCTAssertFalse(framer.hasPendingText)
    }

    func testFlushPendingIsNilWhenNothingIsBuffered() {
        var framer = DeveloperConsoleLineFramer()
        XCTAssertNil(framer.flushPending())
    }

    func testFlushThenUnrelatedWriteProducesTwoDistinctLines() {
        // End-to-end shape of the fix: an idle flush of a stalled fragment, followed by an
        // unrelated writer's complete line, must never be concatenated into one entry.
        var framer = DeveloperConsoleLineFramer()
        _ = framer.append("stalled fragment")

        let flushed = framer.flushPending()
        XCTAssertEqual(flushed, "stalled fragment")

        let unrelated = framer.append("connected\n")
        XCTAssertEqual(unrelated, ["connected"])
    }

    func testResetDiscardsBufferedFragmentWithoutEmittingIt() {
        var framer = DeveloperConsoleLineFramer()
        _ = framer.append("partial line before clear")

        framer.reset()

        XCTAssertFalse(framer.hasPendingText)
        XCTAssertNil(framer.flushPending())
    }

    func testCarriageReturnNewlineIsTreatedAsASingleTerminator() {
        var framer = DeveloperConsoleLineFramer()
        let lines = framer.append("[A][INFO] windows-style\r\n[B][INFO] next\r\n")

        XCTAssertEqual(lines, ["[A][INFO] windows-style", "[B][INFO] next"])
    }
}
