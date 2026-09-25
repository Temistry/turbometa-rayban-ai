import ImageIO
import XCTest
import UIKit
@testable import CameraAccess

final class OpenClawMediaMetadataWriterTests: XCTestCase {
    private func jpegData() throws -> Data {
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        let image = UIGraphicsImageRenderer(
            size: CGSize(width: 64, height: 48),
            format: format
        ).image { context in
            UIColor.systemPurple.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 64, height: 48))
        }
        return try XCTUnwrap(image.jpegData(compressionQuality: 1))
    }

    func testNoLocationReturnsOriginalBytes() throws {
        let original = try jpegData()

        let result = OpenClawMediaMetadataWriter.jpegData(
            original,
            adding: nil
        )

        XCTAssertEqual(result, original)
    }

    func testLocationAddsGPSWithoutChangingPixelDimensions() throws {
        let original = try jpegData()
        let location = OpenClawCaptureLocationSnapshot(
            latitude: 37.5,
            longitude: -127.25,
            altitude: 15,
            horizontalAccuracy: 8,
            capturedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )

        let result = try XCTUnwrap(
            OpenClawMediaMetadataWriter.jpegData(
                original,
                adding: location
            )
        )
        let source = try XCTUnwrap(
            CGImageSourceCreateWithData(result as CFData, nil)
        )
        let properties = try XCTUnwrap(
            CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
                as? [CFString: Any]
        )
        let gps = try XCTUnwrap(
            properties[kCGImagePropertyGPSDictionary]
                as? [CFString: Any]
        )

        XCTAssertEqual(
            properties[kCGImagePropertyPixelWidth] as? Int,
            64
        )
        XCTAssertEqual(
            properties[kCGImagePropertyPixelHeight] as? Int,
            48
        )
        XCTAssertEqual(gps[kCGImagePropertyGPSLatitudeRef] as? String, "N")
        XCTAssertEqual(gps[kCGImagePropertyGPSLongitudeRef] as? String, "W")
        XCTAssertEqual(
            try XCTUnwrap(gps[kCGImagePropertyGPSLatitude] as? Double),
            37.5,
            accuracy: 0.000_001
        )
        XCTAssertEqual(
            try XCTUnwrap(gps[kCGImagePropertyGPSLongitude] as? Double),
            127.25,
            accuracy: 0.000_001
        )
    }
}
