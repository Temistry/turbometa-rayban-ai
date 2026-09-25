import UIKit
import XCTest

@testable import CameraAccess

final class OpenClawTransportTests: XCTestCase {
    func testImageAttachmentPreservesJPEGWithinBudget() throws {
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        let image = UIGraphicsImageRenderer(
            size: CGSize(width: 100, height: 100),
            format: format
        ).image { context in
            UIColor.magenta.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 100, height: 100))
        }
        let original = try XCTUnwrap(image.jpegData(compressionQuality: 1.0))

        let prepared = OpenClawImageAttachmentPreparer.prepareJPEGData(original)

        XCTAssertEqual(prepared, original)
    }

    func testOversizedImageAttachmentFitsGatewayBudget() throws {
        let width = 2200
        let height = 2200
        let bytesPerRow = width * 4
        var pixels = [UInt8](repeating: 0, count: bytesPerRow * height)
        for index in pixels.indices {
            pixels[index] = UInt8(truncatingIfNeeded: index &* 31 &+ index / 97)
        }
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let cgImage = try pixels.withUnsafeMutableBytes { buffer -> CGImage in
            let context = try XCTUnwrap(CGContext(
                data: buffer.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: bytesPerRow,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ))
            return try XCTUnwrap(context.makeImage())
        }
        let image = UIImage(cgImage: cgImage)
        let oversized = try XCTUnwrap(image.jpegData(compressionQuality: 1.0))
        guard oversized.count > OpenClawImageAttachmentPreparer.maximumJPEGBytes else {
            throw XCTSkip("Synthetic JPEG did not exceed the gateway budget")
        }

        let prepared = try XCTUnwrap(
            OpenClawImageAttachmentPreparer.prepareJPEGData(oversized)
        )

        XCTAssertLessThanOrEqual(
            prepared.count,
            OpenClawImageAttachmentPreparer.maximumJPEGBytes
        )
        XCTAssertNotEqual(prepared, oversized)
    }

    func testGatewayProtocolNegotiationSupportsVersionFour() {
        XCTAssertEqual(OpenClawNodeService.minimumProtocolVersion, 3)
        XCTAssertEqual(OpenClawNodeService.maximumProtocolVersion, 4)
    }

    func testDisconnectPolicyHandlesEachCurrentGenerationOnce() {
        XCTAssertTrue(
            OpenClawDisconnectPolicy.shouldHandle(
                callbackGeneration: 4,
                currentGeneration: 4,
                handledGeneration: nil,
                isDisconnected: false
            )
        )
        XCTAssertFalse(
            OpenClawDisconnectPolicy.shouldHandle(
                callbackGeneration: 4,
                currentGeneration: 4,
                handledGeneration: 4,
                isDisconnected: false
            )
        )
        XCTAssertFalse(
            OpenClawDisconnectPolicy.shouldHandle(
                callbackGeneration: 3,
                currentGeneration: 4,
                handledGeneration: nil,
                isDisconnected: false
            )
        )
        XCTAssertFalse(
            OpenClawDisconnectPolicy.shouldHandle(
                callbackGeneration: 4,
                currentGeneration: 4,
                handledGeneration: nil,
                isDisconnected: true
            )
        )
    }

    func testConversationDeliveryPhaseClassifiesTimeouts() {
        XCTAssertEqual(
            OpenClawConversationDeliveryPhase.notStarted.timeoutError,
            .responseTimeout
        )
        XCTAssertEqual(
            OpenClawConversationDeliveryPhase.writeStarted.timeoutError,
            .deliveryAmbiguous
        )
        XCTAssertEqual(
            OpenClawConversationDeliveryPhase.writeCompleted.timeoutError,
            .deliveryAmbiguous
        )
        XCTAssertEqual(
            OpenClawConversationDeliveryPhase.gatewayAcknowledged.timeoutError,
            .responseTimeout
        )
    }

    func testConversationDeliveryPhaseClassifiesDisconnects() {
        XCTAssertEqual(
            OpenClawConversationDeliveryPhase.notStarted.disconnectError,
            .disconnected
        )
        XCTAssertEqual(
            OpenClawConversationDeliveryPhase.writeStarted.disconnectError,
            .deliveryAmbiguous
        )
        XCTAssertEqual(
            OpenClawConversationDeliveryPhase.writeCompleted.disconnectError,
            .deliveryAmbiguous
        )
        XCTAssertEqual(
            OpenClawConversationDeliveryPhase.gatewayAcknowledged.disconnectError,
            .responseTimeout
        )
    }

    func testAutomaticConnectionPolicyPreservesPendingBackoff() {
        XCTAssertFalse(
            OpenClawConnectionAttemptPolicy.canAutomaticAttempt(
                hasPendingReconnect: true,
                isAttemptInFlight: false,
                isConnectedOrConnecting: false,
                isApplicationActive: true,
                tokenAvailability: .configured
            )
        )
        XCTAssertTrue(
            OpenClawConnectionAttemptPolicy.canAutomaticAttempt(
                hasPendingReconnect: false,
                isAttemptInFlight: false,
                isConnectedOrConnecting: false,
                isApplicationActive: true,
                tokenAvailability: .configured
            )
        )
    }

    func testAutomaticConnectionPolicyRequiresForegroundAndToken() {
        XCTAssertFalse(
            OpenClawConnectionAttemptPolicy.canAutomaticAttempt(
                hasPendingReconnect: false,
                isAttemptInFlight: false,
                isConnectedOrConnecting: false,
                isApplicationActive: false,
                tokenAvailability: .configured
            )
        )
        XCTAssertFalse(
            OpenClawConnectionAttemptPolicy.canAutomaticAttempt(
                hasPendingReconnect: false,
                isAttemptInFlight: false,
                isConnectedOrConnecting: false,
                isApplicationActive: true,
                tokenAvailability: .temporarilyUnavailable
            )
        )
    }

    func testForegroundConnectionPolicyDoesNotBypassScheduledReconnect() {
        XCTAssertFalse(
            OpenClawConnectionAttemptPolicy.shouldConnectOnForeground(
                hasPendingReconnect: true,
                pendingForegroundReconnect: true,
                isEnabledAndDisconnected: true
            )
        )
        XCTAssertTrue(
            OpenClawConnectionAttemptPolicy.shouldConnectOnForeground(
                hasPendingReconnect: false,
                pendingForegroundReconnect: true,
                isEnabledAndDisconnected: false
            )
        )
    }

    func testStableConnectionPolicyResetsOnlyForTheSameGenerationWhileConnected() {
        // Same generation, still connected 10s later: safe to reset the backoff counter.
        XCTAssertTrue(
            OpenClawStableConnectionPolicy.shouldResetReconnectAttempts(
                timerGeneration: 2,
                currentGeneration: 2,
                isConnected: true
            )
        )
        // The connection churned (reconnected or was replaced) since the timer was scheduled —
        // resetting now would wipe out backoff state for a connection that already flapped.
        XCTAssertFalse(
            OpenClawStableConnectionPolicy.shouldResetReconnectAttempts(
                timerGeneration: 2,
                currentGeneration: 3,
                isConnected: true
            )
        )
        // Same generation but no longer connected (e.g. dropped right before the timer fired).
        XCTAssertFalse(
            OpenClawStableConnectionPolicy.shouldResetReconnectAttempts(
                timerGeneration: 2,
                currentGeneration: 2,
                isConnected: false
            )
        )
        // Both stale generation and disconnected.
        XCTAssertFalse(
            OpenClawStableConnectionPolicy.shouldResetReconnectAttempts(
                timerGeneration: 1,
                currentGeneration: 5,
                isConnected: false
            )
        )
    }

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
