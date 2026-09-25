import XCTest
@testable import CameraAccess

@MainActor
final class GalvisOpenClawSessionTests: XCTestCase {
    func testSuccessfulTurnsResetFailureBudgetForContinuousConversation() {
        var policy = GalvisConversationLoopPolicy()

        XCTAssertEqual(policy.recoveryAction(for: .emptyTranscript), .retryListening)
        XCTAssertEqual(policy.consecutiveFailures, 1)

        policy.recordSuccessfulTurn()

        XCTAssertEqual(policy.consecutiveFailures, 0)
        XCTAssertEqual(policy.recoveryAction(for: .transient), .retryListening)
        XCTAssertEqual(policy.consecutiveFailures, 1)
    }

    func testSecondQuestionUsesTheSameContinuousLoopBudget() {
        var policy = GalvisConversationLoopPolicy()

        policy.recordSuccessfulTurn()
        policy.recordSuccessfulTurn()

        XCTAssertEqual(policy.consecutiveFailures, 0)
        XCTAssertEqual(policy.recoveryAction(for: .emptyTranscript), .retryListening)
    }

    func testTransientSpeechAndTTSHandoffFailuresRetryListening() {
        let recoverableFailures: [GalvisConversationFailure] = [
            .emptyTranscript,
            .transient
        ]

        for failure in recoverableFailures {
            XCTAssertEqual(
                GalvisConversationRecoveryPolicy.action(for: failure),
                .retryListening
            )
        }
    }

    func testReconnectableGatewayFailuresWaitForNewUtterance() {
        let reconnectableFailures: [GalvisConversationFailure] = [
            .connectionFailed,
            .disconnected
        ]

        for failure in reconnectableFailures {
            XCTAssertEqual(
                GalvisConversationRecoveryPolicy.action(for: failure),
                .reconnectThenListen
            )
        }
    }

    func testGatewayTimeoutDoesNotRequestReplay() {
        XCTAssertEqual(
            GalvisConversationRecoveryPolicy.action(for: .responseTimeout),
            .retryListening
        )
        XCTAssertNotEqual(
            GalvisConversationRecoveryPolicy.action(for: .responseTimeout),
            .reconnectThenListen
        )
    }

    func testAmbiguousDeliveryAndCancellationStopWithoutRetry() {
        let terminalFailures: [GalvisConversationFailure] = [
            .deliveryAmbiguous,
            .gatewayRejected,
            .notConfigured,
            .permissionDenied,
            .speechUnavailable,
            .cancelled
        ]

        for failure in terminalFailures {
            XCTAssertEqual(
                GalvisConversationRecoveryPolicy.action(for: failure),
                .stop
            )
        }
    }

    func testRetryBudgetStopsAfterMaximumConsecutiveFailures() {
        var policy = GalvisConversationLoopPolicy()

        for attempt in 1...GalvisConversationRecoveryPolicy.maximumConsecutiveFailures {
            XCTAssertEqual(policy.recoveryAction(for: .transient), .retryListening)
            XCTAssertEqual(policy.consecutiveFailures, attempt)
        }

        XCTAssertEqual(policy.recoveryAction(for: .transient), .stop)
        XCTAssertEqual(
            policy.consecutiveFailures,
            GalvisConversationRecoveryPolicy.maximumConsecutiveFailures
        )
    }

    func testRetryBackoffIsBoundedAndMonotonic() {
        let delays = (1...8).map {
            GalvisConversationRecoveryPolicy.retryDelayNanoseconds(forAttempt: $0)
        }

        XCTAssertEqual(Array(delays.prefix(5)), [
            250_000_000,
            500_000_000,
            1_000_000_000,
            2_000_000_000,
            3_000_000_000
        ])
        XCTAssertEqual(delays[5], 3_000_000_000)
        XCTAssertEqual(delays[7], 3_000_000_000)
    }

    func testFrameworkErrorsMapToExpectedRecoveryClasses() {
        XCTAssertEqual(
            GalvisConversationRecoveryPolicy.failure(
                for: GalvisSpeechRecognizer.RecognitionError.emptyTranscript
            ),
            .emptyTranscript
        )
        XCTAssertEqual(
            GalvisConversationRecoveryPolicy.failure(
                for: OpenClawConversationError.disconnected
            ),
            .disconnected
        )
        XCTAssertEqual(
            GalvisConversationRecoveryPolicy.failure(
                for: OpenClawConversationError.deliveryAmbiguous
            ),
            .deliveryAmbiguous
        )
        XCTAssertEqual(
            GalvisConversationRecoveryPolicy.failure(for: CancellationError()),
            .cancelled
        )
    }
}
