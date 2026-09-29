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

    func testRedactsSyntheticAccessoryDisplayNameSuffix() {
        let input = """
        accessoryDisplayName: Ray-Ban Meta-4F2A
        peripheralName = "Ray-Ban Meta (4F2A9C)"
        localName: Oakley Meta-1A2B3C
        """

        let output = SensitiveDataRedactor.redact(input)

        [
            "4F2A",
            "4F2A9C",
            "1A2B3C",
        ].forEach { suffix in
            XCTAssertFalse(output.contains(suffix), "마스킹되지 않은 액세서리 표시 이름 접미사: \(suffix)")
        }
        // The marketing name itself is not a secret and must survive redaction.
        XCTAssertTrue(output.contains("Ray-Ban Meta"))
        XCTAssertTrue(output.contains("Oakley Meta"))
        XCTAssertTrue(output.contains("<식별정보 숨김>"))
    }

    func testPreservesAccessoryDisplayNameWithoutSyntheticSuffix() {
        let input = "accessoryDisplayName: Ray-Ban Meta Glasses"
        let output = SensitiveDataRedactor.redact(input)

        // No hex-looking disambiguation suffix present, so nothing should be masked here.
        XCTAssertEqual(output, input)
    }

    func testRedactsFirmwareAndBuildIdentifiers() {
        let input = """
        firmwareVersion: 20.3.145-release
        firmware=20.3.145
        buildNumber: 1452
        buildVersion=B20452
        """

        let output = SensitiveDataRedactor.redact(input)

        [
            "20.3.145-release",
            "1452",
            "B20452",
        ].forEach { value in
            XCTAssertFalse(output.contains(value), "마스킹되지 않은 펌웨어/빌드 값: \(value)")
        }
        XCTAssertTrue(output.contains("<식별정보 숨김>"))
    }

    func testRedactsLocalAndRemoteNodeIdentifiers() {
        let input = """
        nodeId: rayban-a1b2c3d4
        localNode=rayban-abcdef01
        remoteNodeId: gateway-primary-9f8e
        localNodeId=node-local-77
        """

        let output = SensitiveDataRedactor.redact(input)

        [
            "rayban-a1b2c3d4",
            "rayban-abcdef01",
            "gateway-primary-9f8e",
            "node-local-77",
        ].forEach { value in
            XCTAssertFalse(output.contains(value), "마스킹되지 않은 노드 식별자: \(value)")
        }
        XCTAssertTrue(output.contains("<식별정보 숨김>"))
    }

    func testRedactsServiceAndChannelIdentifiers() {
        let input = """
        serviceUUID: 0000180a-0000-1000-8000-00805f9b34fb
        serviceId=svc-gateway-42
        characteristicUUID: 00002a29-0000-1000-8000-00805f9b34fb
        channelId=chan-5f2a
        channel_id: 42
        """

        let output = SensitiveDataRedactor.redact(input)

        [
            "svc-gateway-42",
            "chan-5f2a",
        ].forEach { value in
            XCTAssertFalse(output.contains(value), "마스킹되지 않은 서비스/채널 식별자: \(value)")
        }
        // UUID-shaped service/characteristic values are also caught by the generic UUID rule.
        XCTAssertFalse(output.contains("0000180a-0000-1000-8000-00805f9b34fb"))
        XCTAssertFalse(output.contains("00002a29-0000-1000-8000-00805f9b34fb"))
        XCTAssertFalse(output.contains("42"), "channel_id 숫자 값이 마스킹되지 않음")
        XCTAssertTrue(output.contains("<식별정보 숨김>"))
    }

    func testRedactsWhitespaceSeparatedRuntimeIdentifiers() {
        let input = """
        remoteNodeId 731904
        service ID: 48217
        connectionID 991204
        IAPAppConnectionIDKey = 830175;
        IAPAppAccessoryFirmwareRevisionKey = 21.8.304-test;
        For Ray-Ban Meta - 640291 (transport 2)
        """

        let output = SensitiveDataRedactor.redact(input)

        [
            "731904",
            "48217",
            "991204",
            "830175",
            "21.8.304-test",
            "640291",
        ].forEach { value in
            XCTAssertFalse(output.contains(value), "마스킹되지 않은 런타임 식별자: \(value)")
        }
        XCTAssertTrue(output.contains("For Ray-Ban Meta - <식별정보 숨김> (transport 2)"))
        XCTAssertTrue(output.contains("<식별정보 숨김>"))
    }
}
