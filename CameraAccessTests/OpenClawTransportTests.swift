import XCTest

@testable import CameraAccess

final class OpenClawTransportTests: XCTestCase {
    func testMeshnetCIDRBoundariesAreExact() {
        XCTAssertTrue(OpenClawGatewayEndpoint.isMeshnetHost("100.64.0.0"))
        XCTAssertTrue(OpenClawGatewayEndpoint.isMeshnetHost("100.127.255.255"))
        XCTAssertFalse(OpenClawGatewayEndpoint.isMeshnetHost("100.63.255.255"))
        XCTAssertFalse(OpenClawGatewayEndpoint.isMeshnetHost("100.128.0.0"))
    }

    func testMeshnetRequiresAValidIPv4Literal() {
        XCTAssertFalse(OpenClawGatewayEndpoint.isMeshnetHost("100.attacker.example"))
        XCTAssertFalse(OpenClawGatewayEndpoint.isMeshnetHost("100.64.1"))
        XCTAssertFalse(OpenClawGatewayEndpoint.isMeshnetHost("100.64.1.999"))
        XCTAssertFalse(OpenClawGatewayEndpoint.isMeshnetHost("100..64.1"))
    }

    func testMeshnetModeAllowsDefaultAndExplicitPlainWebSocket() throws {
        let defaultURL = try OpenClawGatewayEndpoint.makeURL(
            rawHost: "100.64.0.1",
            defaultPort: 18789,
            transportMode: .meshnet
        )
        let explicitURL = try OpenClawGatewayEndpoint.makeURL(
            rawHost: "ws://100.127.255.255",
            defaultPort: 18789,
            transportMode: .meshnet
        )

        XCTAssertEqual(defaultURL.scheme, "ws")
        XCTAssertEqual(defaultURL.port, 18789)
        XCTAssertEqual(explicitURL.scheme, "ws")
    }

    func testStandardModeRetainsWSSForMeshnetAddress() throws {
        let defaultURL = try OpenClawGatewayEndpoint.makeURL(
            rawHost: "100.64.0.1",
            defaultPort: 18789,
            transportMode: .standard
        )
        XCTAssertEqual(defaultURL.scheme, "wss")

        XCTAssertThrowsError(
            try OpenClawGatewayEndpoint.makeURL(
                rawHost: "ws://100.64.0.1",
                defaultPort: 18789,
                transportMode: .standard
            )
        )

        XCTAssertNoThrow(
            try OpenClawGatewayEndpoint.makeURL(
                rawHost: "wss://100.64.0.1",
                defaultPort: 18789,
                transportMode: .standard
            )
        )
    }

    func testMeshnetModeKeepsWSSAvailable() {
        XCTAssertNoThrow(
            try OpenClawGatewayEndpoint.makeURL(
                rawHost: "wss://gateway.example.com",
                defaultPort: 18789,
                transportMode: .meshnet
            )
        )
    }

    func testMeshnetPlainWebSocketSelectsNetworkTransport() throws {
        for host in ["100.64.0.0", "100.127.255.255"] {
            let url = try OpenClawGatewayEndpoint.makeURL(
                rawHost: host,
                defaultPort: 18789,
                transportMode: .meshnet
            )

            XCTAssertEqual(
                OpenClawWebSocketTransportSelector.kind(for: url, transportMode: .meshnet),
                .meshnetNetwork
            )
        }
    }

    func testOnlyValidatedMeshnetPlainWebSocketSelectsNetworkTransport() throws {
        let secureMeshnetURL = try OpenClawGatewayEndpoint.makeURL(
            rawHost: "wss://100.64.0.1",
            defaultPort: 18789,
            transportMode: .meshnet
        )
        let localURL = try OpenClawGatewayEndpoint.makeURL(
            rawHost: "192.168.1.10",
            defaultPort: 18789,
            transportMode: .meshnet
        )
        let standardMeshnetURL = try OpenClawGatewayEndpoint.makeURL(
            rawHost: "100.64.0.1",
            defaultPort: 18789,
            transportMode: .standard
        )

        XCTAssertEqual(
            OpenClawWebSocketTransportSelector.kind(for: secureMeshnetURL, transportMode: .meshnet),
            .urlSession
        )
        XCTAssertEqual(
            OpenClawWebSocketTransportSelector.kind(for: localURL, transportMode: .meshnet),
            .urlSession
        )
        XCTAssertEqual(
            OpenClawWebSocketTransportSelector.kind(for: standardMeshnetURL, transportMode: .standard),
            .urlSession
        )
    }

    func testGatewayPathIsPreservedWithoutUnsafeComponents() throws {
        let url = try OpenClawGatewayEndpoint.makeURL(
            rawHost: "wss://gateway.example.com/openclaw",
            defaultPort: 18789,
            transportMode: .meshnet
        )
        XCTAssertEqual(url.path, "/openclaw")
    }

    func testMeshnetModeStillRejectsPlainWebSocketForPublicTargets() {
        for rawHost in [
            "ws://gateway.example.com",
            "ws://100.attacker.example",
            "ws://100.63.255.255",
            "ws://100.128.0.0",
            "ws://8.8.8.8"
        ] {
            XCTAssertThrowsError(
                try OpenClawGatewayEndpoint.makeURL(
                    rawHost: rawHost,
                    defaultPort: 18789,
                    transportMode: .meshnet
                ),
                "Expected public or invalid Meshnet target to be rejected: \(rawHost)"
            )
        }
    }

    func testLocalNetworkAndPublicDefaultsAreUnchanged() throws {
        let localURL = try OpenClawGatewayEndpoint.makeURL(
            rawHost: "192.168.1.10",
            defaultPort: 18789,
            transportMode: .standard
        )
        let publicURL = try OpenClawGatewayEndpoint.makeURL(
            rawHost: "gateway.example.com",
            defaultPort: 18789,
            transportMode: .standard
        )

        XCTAssertEqual(localURL.scheme, "ws")
        XCTAssertEqual(publicURL.scheme, "wss")
        XCTAssertFalse(OpenClawGatewayEndpoint.isLocalOrPrivateHost("100.64.0.1"))
    }

    func testCredentialsQueryAndFragmentAreRejectedInBothModes() {
        for mode in OpenClawTransportMode.allCases {
            for rawHost in [
                "wss://user@example.com",
                "wss://user:password@example.com",
                "wss://gateway.example.com?token=not-allowed",
                "wss://gateway.example.com#not-allowed"
            ] {
                XCTAssertThrowsError(
                    try OpenClawGatewayEndpoint.makeURL(
                        rawHost: rawHost,
                        defaultPort: 18789,
                        transportMode: mode
                    )
                )
            }
        }
    }

    func testOnlyWebSocketSchemesAreAccepted() {
        XCTAssertThrowsError(
            try OpenClawGatewayEndpoint.makeURL(
                rawHost: "https://gateway.example.com",
                defaultPort: 18789,
                transportMode: .standard
            )
        )
    }

    func testPortValidationAndExplicitPortOverride() throws {
        let url = try OpenClawGatewayEndpoint.makeURL(
            rawHost: "wss://gateway.example.com:443",
            defaultPort: 18789,
            transportMode: .standard
        )
        XCTAssertEqual(url.port, 443)

        XCTAssertThrowsError(
            try OpenClawGatewayEndpoint.makeURL(
                rawHost: "100.64.0.1",
                defaultPort: 0,
                transportMode: .meshnet
            )
        )
        XCTAssertThrowsError(
            try OpenClawGatewayEndpoint.makeURL(
                rawHost: "wss://gateway.example.com:65536",
                defaultPort: 18789,
                transportMode: .standard
            )
        )
    }

    func testBareHostWithUnsafeSyntaxIsRejected() {
        for rawHost in [
            "gateway.example.com/openclaw",
            "gateway.example.com?token=not-allowed",
            "gateway.example.com#not-allowed",
            "100.64.0.1:18789"
        ] {
            XCTAssertThrowsError(
                try OpenClawGatewayEndpoint.makeURL(
                    rawHost: rawHost,
                    defaultPort: 18789,
                    transportMode: .meshnet
                )
            )
        }
    }
}
