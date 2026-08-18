import Foundation
import XCTest

@testable import CameraAccess

final class OpenClawGatewaySpeechTests: XCTestCase {
    func testSpeechRatesMapToBoundedGatewayValues() {
        XCTAssertEqual(OpenClawSpeechRate.slow.gatewaySpeed, 0.85)
        XCTAssertEqual(OpenClawSpeechRate.normal.gatewaySpeed, 1.0)
        XCTAssertEqual(OpenClawSpeechRate.fast.gatewaySpeed, 1.15)
    }

    func testDecodesSupportedAudioResponse() throws {
        let expected = Data([0x49, 0x44, 0x33, 0x04])
        let audio = try OpenClawSpeechAudio.decode(payload: [
            "audioBase64": expected.base64EncodedString(),
            "provider": "test-provider",
            "mimeType": "audio/mpeg",
            "outputFormat": "mp3",
            "fileExtension": "mp3"
        ])

        XCTAssertEqual(audio.data, expected)
        XCTAssertEqual(audio.provider, "test-provider")
        XCTAssertEqual(audio.mimeType, "audio/mpeg")
        XCTAssertEqual(audio.outputFormat, "mp3")
        XCTAssertEqual(audio.fileExtension, "mp3")
    }

    func testAcceptsSupportedFileExtensionWithoutMimeType() throws {
        let audio = try OpenClawSpeechAudio.decode(payload: [
            "audioBase64": Data([0x52, 0x49, 0x46, 0x46]).base64EncodedString(),
            "provider": "test-provider",
            "fileExtension": "WAV"
        ])

        XCTAssertEqual(audio.fileExtension, "wav")
    }

    func testRejectsMalformedBase64() {
        XCTAssertThrowsError(
            try OpenClawSpeechAudio.decode(payload: [
                "audioBase64": "not-base64!",
                "provider": "test-provider",
                "mimeType": "audio/mpeg"
            ])
        ) { error in
            guard case OpenClawSpeechError.invalidAudio = error else {
                return XCTFail("Expected invalidAudio, received \(error)")
            }
        }
    }

    func testRejectsUnsupportedAudioFormat() {
        XCTAssertThrowsError(
            try OpenClawSpeechAudio.decode(payload: [
                "audioBase64": Data([0x4f, 0x67, 0x67, 0x53]).base64EncodedString(),
                "provider": "test-provider",
                "mimeType": "audio/ogg",
                "outputFormat": "opus"
            ])
        ) { error in
            guard case OpenClawSpeechError.unsupportedAudioFormat = error else {
                return XCTFail("Expected unsupportedAudioFormat, received \(error)")
            }
        }
    }

    func testRejectsOversizedDecodedAudio() {
        let oversized = Data(
            repeating: 0,
            count: OpenClawSpeechAudio.maximumDecodedBytes + 1
        )

        XCTAssertThrowsError(
            try OpenClawSpeechAudio.decode(payload: [
                "audioBase64": oversized.base64EncodedString(),
                "provider": "test-provider",
                "mimeType": "audio/mpeg"
            ])
        ) { error in
            guard case OpenClawSpeechError.invalidAudio = error else {
                return XCTFail("Expected invalidAudio, received \(error)")
            }
        }
    }
}
