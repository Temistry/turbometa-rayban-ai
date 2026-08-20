import AVFoundation
import XCTest
import UIKit
@testable import CameraAccess

final class OpenClawVideoFrameExtractorTests: XCTestCase {
    func testMissingVideoTrackIsReported() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("mp4")
        try Data().write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        do {
            _ = try await OpenClawVideoFrameExtractor.representativeFrames(
                from: url
            )
            XCTFail("Expected noVideoTrack")
        } catch let error as OpenClawVideoFrameExtractorError {
            XCTAssertEqual(error, .noVideoTrack)
        }
    }

    func testExtractsRepresentativeFramesAndQualityMetadata() async throws {
        let recorder = OpenClawVideoRecorder()
        try recorder.start()
        let frame = image(size: CGSize(width: 160, height: 240))
        for index in 0..<16 {
            recorder.appendFrame(
                frame,
                hostTime: 100 + Double(index) / OpenClawVideoRecorder.maxInputFPS
            )
        }
        try await Task.sleep(nanoseconds: 400_000_000)
        let url = try await recorder.finalize()
        defer { try? FileManager.default.removeItem(at: url) }

        let frames = try await OpenClawVideoFrameExtractor.representativeFrames(
            from: url,
            maxFrames: 6
        )
        let loadedMetadata = await OpenClawVideoFrameExtractor.qualityMetadata(
            from: url
        )
        let metadata = try XCTUnwrap(loadedMetadata)
        let contactSheet = try await OpenClawVideoFrameExtractor.contactSheetJPEG(
            from: url
        )

        XCTAssertFalse(frames.isEmpty)
        XCTAssertLessThanOrEqual(frames.count, 6)
        XCTAssertEqual(metadata.width, 160)
        XCTAssertEqual(metadata.height, 240)
        XCTAssertGreaterThan(metadata.durationSeconds, 0)
        XCTAssertGreaterThan(contactSheet.count, 0)
        XCTAssertLessThanOrEqual(
            contactSheet.count,
            OpenClawVideoContactSheetBuilder.Options.default.maxJPEGBytes
        )
    }

    private func image(size: CGSize) -> UIImage {
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image {
            context in
            UIColor.orange.setFill()
            context.fill(CGRect(origin: .zero, size: size))
        }
    }
}
