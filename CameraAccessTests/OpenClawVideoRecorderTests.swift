import AVFoundation
import XCTest
import UIKit
@testable import CameraAccess

final class OpenClawVideoRecorderTests: XCTestCase {
    private func image(
        size: CGSize = CGSize(width: 64, height: 64)
    ) -> UIImage {
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        return renderer.image { context in
            UIColor.blue.setFill()
            context.fill(CGRect(origin: .zero, size: size))
        }
    }

    func testFinalizeWithoutFramesFailsAndRemovesOutput() async throws {
        let recorder = OpenClawVideoRecorder()
        try recorder.start()

        do {
            _ = try await recorder.finalize()
            XCTFail("Expected noFramesRecorded")
        } catch let error as OpenClawVideoRecorderError {
            XCTAssertEqual(error, .noFramesRecorded)
        }
    }

    func testRecordingShorterThanMinimumFails() async throws {
        let recorder = OpenClawVideoRecorder()
        try recorder.start()
        let frame = image()
        recorder.appendFrame(frame, hostTime: 100)
        recorder.appendFrame(frame, hostTime: 100.2)
        try await Task.sleep(nanoseconds: 100_000_000)

        do {
            _ = try await recorder.finalize()
            XCTFail("Expected recordingTooShort")
        } catch let error as OpenClawVideoRecorderError {
            XCTAssertEqual(error, .recordingTooShort)
        }
    }

    func testBoundedRecordingProducesMP4() async throws {
        let recorder = OpenClawVideoRecorder()
        try recorder.start()
        let frame = image()
        for index in 0..<10 {
            recorder.appendFrame(
                frame,
                hostTime: 200 + Double(index) * 0.1
            )
        }
        try await Task.sleep(nanoseconds: 300_000_000)

        let url = try await recorder.finalize()
        defer { try? FileManager.default.removeItem(at: url) }

        let attributes = try FileManager.default.attributesOfItem(
            atPath: url.path
        )
        let byteSize = attributes[.size] as? Int ?? 0
        XCTAssertGreaterThan(byteSize, 0)
        XCTAssertLessThanOrEqual(
            byteSize,
            OpenClawVideoRecorder.maxFileSizeBytes + 2 * 1024 * 1024
        )
    }

    func testMaximumInputRateAndSourceDimensionsArePreserved() async throws {
        XCTAssertEqual(OpenClawVideoRecorder.maxInputFPS, 30)

        let recorder = OpenClawVideoRecorder()
        try recorder.start()
        let sourceSize = CGSize(width: 720, height: 1280)
        let frame = image(size: sourceSize)
        for index in 0..<20 {
            recorder.appendFrame(
                frame,
                hostTime: 250 + Double(index) / OpenClawVideoRecorder.maxInputFPS
            )
        }
        try await Task.sleep(nanoseconds: 500_000_000)

        let url = try await recorder.finalize()
        defer { try? FileManager.default.removeItem(at: url) }
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        let track = try XCTUnwrap(tracks.first)
        let naturalSize = try await track.load(.naturalSize)

        XCTAssertEqual(naturalSize.width, sourceSize.width, accuracy: 1)
        XCTAssertEqual(naturalSize.height, sourceSize.height, accuracy: 1)
    }

    func testCancelRemovesPartialRecording() throws {
        let recorder = OpenClawVideoRecorder()
        try recorder.start()
        recorder.appendFrame(image(), hostTime: 300)
        recorder.cancel()
        XCTAssertEqual(recorder.state, .cancelled)
    }

    func testCancelDuringFinalizationReturnsCancelled() async throws {
        let recorder = OpenClawVideoRecorder()
        try recorder.start()
        let frame = image(size: CGSize(width: 320, height: 240))
        for index in 0..<12 {
            recorder.appendFrame(
                frame,
                hostTime: 400 + Double(index) * 0.1
            )
        }
        try await Task.sleep(nanoseconds: 300_000_000)

        let finalizeTask = Task {
            try await recorder.finalize()
        }
        recorder.cancel()

        do {
            let url = try await finalizeTask.value
            defer { try? FileManager.default.removeItem(at: url) }
            XCTFail("Expected cancelled finalization")
        } catch let error as OpenClawVideoRecorderError {
            XCTAssertEqual(error, .cancelled)
        }
        XCTAssertEqual(recorder.state, .cancelled)
    }

    func testManualFinalizeJoinsAutomaticFinalization() async throws {
        let recorder = OpenClawVideoRecorder()
        let limitReached = expectation(description: "Recorder reached limit")
        recorder.onLimitReached = { _ in
            limitReached.fulfill()
        }
        try recorder.start()

        let frame = image(size: CGSize(width: 320, height: 240))
        recorder.appendFrame(frame, hostTime: 500)
        recorder.appendFrame(frame, hostTime: 500.6)
        recorder.appendFrame(
            frame,
            hostTime: 500 + OpenClawVideoRecorder.maxDuration
        )

        await fulfillment(of: [limitReached], timeout: 2)
        let url = try await recorder.finalize()
        defer { try? FileManager.default.removeItem(at: url) }

        XCTAssertEqual(recorder.state, .finished)
        let attributes = try FileManager.default.attributesOfItem(
            atPath: url.path
        )
        XCTAssertGreaterThan(attributes[.size] as? Int ?? 0, 0)
    }
}
