// Deterministic session-policy tests. They cover identity, reconnect, timeout,
// and duplicate/late response behavior without requiring a BLE peripheral.
import XCTest
@testable import ProMist

final class ProMistBLESessionStateTests: XCTestCase {
    func testIdentityMismatchFailsBeforeAuthentication() {
        var session = ProMistBLESessionState()
        session.beginConnection(expectedDeviceID: 42)

        XCTAssertEqual(session.receiveIdentity(43), .rejectMismatch)
        XCTAssertEqual(session.phase, .failed)
    }

    func testAuthenticationFailureAndTimeoutAreDeterministic() {
        var failed = ProMistBLESessionState()
        failed.beginConnection(expectedDeviceID: 42)
        XCTAssertEqual(failed.receiveIdentity(42), .authenticate(deviceID: 42))
        XCTAssertTrue(failed.authenticationFailed(deviceID: 42))
        XCTAssertEqual(failed.phase, .failed)

        var timedOut = ProMistBLESessionState()
        timedOut.beginConnection(expectedDeviceID: 42)
        _ = timedOut.receiveIdentity(42)
        XCTAssertTrue(timedOut.authenticationTimedOut(deviceID: 42))
        XCTAssertEqual(timedOut.phase, .failed)
    }

    func testConnectionTimeoutFailsOnlyAnActiveConnectionAttempt() {
        var session = ProMistBLESessionState()
        XCTAssertFalse(session.connectionTimedOut())

        session.beginConnection(expectedDeviceID: 42)
        XCTAssertTrue(session.connectionTimedOut())
        XCTAssertEqual(session.phase, .failed)
        XCTAssertFalse(session.connectionTimedOut())
    }

    func testUserCancellationMakesDelayedIdentityCallbackStale() {
        var session = ProMistBLESessionState()
        session.beginConnection(expectedDeviceID: 42)
        session.reset()

        XCTAssertEqual(session.receiveIdentity(42), .ignoreStale)
        XCTAssertEqual(session.phase, .idle)
    }

    func testRepeatedDisconnectNeverSchedulesReconnect() {
        var session = ProMistBLESessionState()
        session.beginConnection(expectedDeviceID: 42)
        XCTAssertEqual(session.disconnect(reconnectRequested: false), .finish)
        XCTAssertEqual(session.disconnect(reconnectRequested: false), .finish)
    }

    func testIdentityWaitsForSecurityNotificationsBeforeAuthentication() {
        var session = ProMistBLESessionState()
        session.beginConnection(expectedDeviceID: 42)

        XCTAssertEqual(
            session.receiveIdentity(42, securityNotificationsReady: false),
            .waitForSecurity(deviceID: 42)
        )
        XCTAssertEqual(session.phase, .connecting(expectedDeviceID: 42))
        XCTAssertEqual(
            session.receiveIdentity(42, securityNotificationsReady: true),
            .authenticate(deviceID: 42)
        )
        XCTAssertEqual(session.phase, .authenticating(deviceID: 42))
    }

    func testDisconnectReconnectRequiresAReadyInteractiveSession() {
        var session = ProMistBLESessionState()
        session.beginConnection(expectedDeviceID: 42)
        _ = session.receiveIdentity(42)
        XCTAssertTrue(session.authenticationSucceeded(deviceID: 42))
        XCTAssertEqual(session.phase, .authenticated(deviceID: 42))
        XCTAssertTrue(session.capabilityResolutionSucceeded(deviceID: 42))
        XCTAssertEqual(session.disconnect(reconnectRequested: true), .reconnect)
        XCTAssertEqual(session.phase, .idle)

        session.beginConnection(expectedDeviceID: 42)
        XCTAssertEqual(session.disconnect(reconnectRequested: true), .finish)
    }

    func testAuthenticationAloneDoesNotMakeSessionReady() {
        var session = ProMistBLESessionState()
        session.beginConnection(expectedDeviceID: 42)
        _ = session.receiveIdentity(42)

        XCTAssertTrue(session.authenticationSucceeded(deviceID: 42))
        XCTAssertEqual(session.phase, .authenticated(deviceID: 42))
        XCTAssertEqual(session.disconnect(reconnectRequested: true), .finish)

        session.beginConnection(expectedDeviceID: 42)
        _ = session.receiveIdentity(42)
        XCTAssertTrue(session.authenticationSucceeded(deviceID: 42))
        XCTAssertTrue(session.capabilityResolutionSucceeded(deviceID: 42))
        XCTAssertEqual(session.phase, .ready(deviceID: 42))
    }

    func testServiceInvalidationRequiresFreshIdentityAndAuthentication() {
        var session = ProMistBLESessionState()
        session.beginConnection(expectedDeviceID: 42)
        _ = session.receiveIdentity(42)
        XCTAssertTrue(session.authenticationSucceeded(deviceID: 42))
        XCTAssertTrue(session.capabilityResolutionSucceeded(deviceID: 42))

        session.reset()
        session.beginConnection(expectedDeviceID: 42)
        XCTAssertEqual(session.receiveIdentity(42), .authenticate(deviceID: 42))
        XCTAssertTrue(session.authenticationSucceeded(deviceID: 42))
        XCTAssertTrue(session.capabilityResolutionSucceeded(deviceID: 42))
        XCTAssertEqual(session.phase, .ready(deviceID: 42))
    }

    func testWrongIdentityAfterServiceInvalidationRemainsRejected() {
        var session = ProMistBLESessionState()
        session.beginConnection(expectedDeviceID: 42)
        session.reset()
        session.beginConnection(expectedDeviceID: 42)
        XCTAssertEqual(session.receiveIdentity(43), .rejectMismatch)
    }

    func testDuplicateAndLateResponsesDoNotCompleteAnotherCommand() {
        var tracker = ProMistBLECommandTracker()
        XCTAssertTrue(tracker.begin(requestID: 7))
        XCTAssertTrue(tracker.receiveResponse(requestID: 7))
        XCTAssertFalse(tracker.receiveResponse(requestID: 7))
        XCTAssertFalse(tracker.receiveResponse(requestID: 99))
    }

    func testTimeoutAndDisconnectInvalidatePendingResponses() {
        var tracker = ProMistBLECommandTracker()
        XCTAssertTrue(tracker.begin(requestID: 7))
        XCTAssertTrue(tracker.timeout(requestID: 7))
        XCTAssertFalse(tracker.receiveResponse(requestID: 7))

        XCTAssertTrue(tracker.begin(requestID: 8))
        tracker.disconnect()
        XCTAssertFalse(tracker.receiveResponse(requestID: 8))
    }


    func testDiagnosticPageDetectsMissingAndDeduplicatesRetry() {
        var page = ProMistBLEDiagnosticPageAssembler(requestID: 7, afterSequence: 0)
        let one = diagnostic(sequence: 1)
        let three = diagnostic(sequence: 3)
        XCTAssertEqual(page.receive(.record(requestID: 7, one)), .waiting)
        XCTAssertEqual(page.receive(.record(requestID: 7, one)), .waiting)
        XCTAssertEqual(page.receive(.record(requestID: 6, diagnostic(sequence: 2))), .waiting)
        XCTAssertEqual(page.receive(.record(requestID: 7, three)), .waiting)
        XCTAssertEqual(page.receive(.complete(requestID: 7, first: 1, last: 3,
                                              count: 3, next: 3, hasMore: false)), .waiting)
        XCTAssertEqual(page.receive(.record(requestID: 7, diagnostic(sequence: 2))),
                       .complete(next: 3, hasMore: false))
        XCTAssertEqual(page.orderedRecords.map(\.sequence), [1, 2, 3])
    }

    func testZeroAndFullDiagnosticPagesUseExplicitHasMore() {
        var empty = ProMistBLEDiagnosticPageAssembler(requestID: 1, afterSequence: 9)
        XCTAssertEqual(empty.receive(.complete(requestID: 1, first: 0, last: 9,
                                               count: 0, next: 9, hasMore: false)),
                       .complete(next: 9, hasMore: false))
        var full = ProMistBLEDiagnosticPageAssembler(requestID: 2, afterSequence: 0)
        for sequence in 1...8 { _ = full.receive(.record(requestID: 2, diagnostic(sequence: UInt32(sequence)))) }
        XCTAssertEqual(full.receive(.complete(requestID: 2, first: 1, last: 8,
                                              count: 8, next: 8, hasMore: true)),
                       .complete(next: 8, hasMore: true))
    }

    func testBreezeTransferRequiresMatchingSlotAndValidatedPreset() {
        var transfer = ProMistBreezeTransferState()
        transfer.begin(slot: 1, presetID: 42)
        XCTAssertEqual(transfer.receive(slot: 0, presetID: 42), .ignored)
        XCTAssertEqual(transfer.receive(slot: 1, presetID: 41), .completedWithoutSelection)
        XCTAssertEqual(transfer.receive(slot: 1, presetID: 42), .ignored)

        transfer.begin(slot: 2, presetID: 42)
        XCTAssertEqual(transfer.receive(slot: 2, presetID: 42), .select(mode: 6))
    }

    private func diagnostic(sequence: UInt32) -> ProMistDiagnostic {
        var data = sequence.littleEndianData + UInt32(1).littleEndianData
        data += UInt16(1).littleEndianData + Data([0, 0])
        data += Int32(0).littleEndianData + Int32(0).littleEndianData
        return ProMistDiagnostic(data: data)!
    }
}
