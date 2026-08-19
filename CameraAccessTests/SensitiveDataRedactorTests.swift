/*
 * Sensitive-data masking regression coverage.
 */

import XCTest

@testable import CameraAccess

final class SensitiveDataRedactorTests: XCTestCase {
    func testRedactsRepresentativeCredentials() {
        let googleKey = "AI" + "zaABCDEFGHIJKLMNOPQRSTUVWXYZ1234567890"
        let input = """
        Authorization: Bearer rawBearerToken
        apiKey: rawAPIKey
        client_secret: rawClientSecret
        \"api_key\": \"rawJSONKey\"
        \"client_secret\": \"rawJSONClientSecret\"
        Cookie: session=rawSessionCookie; path=/
        https://user:password@example.com/path
        rtmps://live.example.com/app/stream?token=rawStreamToken
        sk-abcdefghijklmnop
        \(googleKey)
        eyJheader.payload.signature
        """

        let output = SensitiveDataRedactor.redact(input)

        [
            "rawBearerToken",
            "rawAPIKey",
            "rawClientSecret",
            "rawJSONKey",
            "rawJSONClientSecret",
            "rawSessionCookie",
            "user:password",
            "rawStreamToken",
            "sk-abcdefghijklmnop",
            googleKey,
            "eyJheader.payload.signature",
        ].forEach { secret in
            XCTAssertFalse(output.contains(secret), "마스킹되지 않은 값: \(secret)")
        }
        XCTAssertTrue(output.contains("<보안상 숨김>"))
        XCTAssertTrue(output.contains("<인증정보 숨김>"))
        XCTAssertTrue(output.contains("<송출 경로 숨김>"))
    }

    func testRedactsAccessoryIdentifiersAndPreservesTTSMetadata() {
        let input = """
        세션 ID: 834BBFAC-BEA4-420A-BDE5-F555A443505C
        ACCExternalAccessoryPPIDKey = 1ccd448ce2094bff;
        ACCExternalAccessoryPrimaryUUID = "082A06F3-E05A-43DD-9584-75A56720D064";
        ACCExternalAccessoryProtocolEndpointUUID = "082A06F3-E05A-43DD-9584-75A56720D064";
        IAPAppAccessoryMacAddressKey = "80:AA:1C:77:8F:A4";
        IAPAppAccessorySerialNumberKey = 4W0ZWF5J2Z06H5;
        IAPAppAccessoryNameKey = "Oakley | Meta HSTN";
        IAPAppAccessoryPreferredAppKey = HXH6UQBHD4;
        IAPAppAccessoryCertDataKey = {length = 609, bytes = 0x3082025d 06092a86};
        socketPath from app = /var/mobile/Library/ExternalAccessory/private-socket
        [TTS][AUDIO] outputs=[BluetoothA2DPOutput]
        [TTS][ERROR] code=-50 request=ABC12345
        """

        let output = SensitiveDataRedactor.redact(input)

        [
            "834BBFAC-BEA4-420A-BDE5-F555A443505C",
            "1ccd448ce2094bff",
            "082A06F3-E05A-43DD-9584-75A56720D064",
            "80:AA:1C:77:8F:A4",
            "4W0ZWF5J2Z06H5",
            "Oakley | Meta HSTN",
            "HXH6UQBHD4",
            "0x3082025d",
            "private-socket",
        ].forEach { identifier in
            XCTAssertFalse(output.contains(identifier), "마스킹되지 않은 식별정보: \(identifier)")
        }
        XCTAssertTrue(output.contains("BluetoothA2DPOutput"))
        XCTAssertTrue(output.contains("code=-50"))
        XCTAssertTrue(output.contains("request=ABC12345"))
    }

    func testRedactsMetricKitLikeJSONPayload() {
        let input = """
        {
          "meta": {
            "access_token": "metricToken",
            "image": "\(String(repeating: "A", count: 120))"
          },
          "endpoint": "https://example.com/report?api_key=metricKey"
        }
        """

        let output = SensitiveDataRedactor.redact(input)

        XCTAssertFalse(output.contains("metricToken"))
        XCTAssertFalse(output.contains("metricKey"))
        XCTAssertFalse(output.contains(String(repeating: "A", count: 120)))
        XCTAssertTrue(output.contains("<대용량 데이터 생략>"))
    }
}
