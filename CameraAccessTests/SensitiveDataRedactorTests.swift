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
