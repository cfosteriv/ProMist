import XCTest
@testable import ProMist

final class ProMistBLEConnectionPolicyTests: XCTestCase {
    private let target = ProMistBLEConnectionPolicy.Target(
        deviceID: 0x123456,
        name: "ProMist-123456"
    )

    func testUserCancellationRejectsLateDidConnectAndSuppressesReconnect() {
        var policy = ProMistBLEConnectionPolicy()
        let peripheral = UUID()
        _ = policy.beginInteractiveSession(for: target)
        _ = policy.receiveAdvertisement(
            peripheralIdentifier: peripheral,
            observedName: target.name
        )

        XCTAssertEqual(
            policy.requestDisconnect(peripheralIdentifier: peripheral),
            .cancelConnection(peripheralIdentifier: peripheral)
        )
        XCTAssertEqual(
            policy.receiveConnected(peripheralIdentifier: peripheral),
            .cancelConnection(peripheralIdentifier: peripheral)
        )
        XCTAssertEqual(
            policy.receiveDisconnected(peripheralIdentifier: peripheral),
            .ignore
        )
        XCTAssertEqual(policy.state, .idle)
    }

    func testSupersededAttemptRejectsStaleConnectionCallback() {
        var policy = ProMistBLEConnectionPolicy()
        let stalePeripheral = UUID()
        let currentPeripheral = UUID()
        _ = policy.beginInteractiveSession(for: target)
        _ = policy.receiveAdvertisement(
            peripheralIdentifier: stalePeripheral,
            observedName: target.name
        )
        let firstGeneration = policy.attemptGeneration

        _ = policy.beginKnownDeviceResolution(for: target)
        _ = policy.receiveAdvertisement(
            peripheralIdentifier: currentPeripheral,
            observedName: target.name
        )
        XCTAssertGreaterThan(policy.attemptGeneration, firstGeneration)
        XCTAssertEqual(
            policy.receiveConnected(peripheralIdentifier: stalePeripheral),
            .cancelConnection(peripheralIdentifier: stalePeripheral)
        )
        XCTAssertEqual(
            policy.receiveConnected(peripheralIdentifier: currentPeripheral),
            .discoverServices(
                peripheralIdentifier: currentPeripheral,
                attemptGeneration: policy.attemptGeneration
            )
        )
    }

    func testSamePeripheralStaleConnectIsRejectedUntilCancellationCompletes() {
        var policy = ProMistBLEConnectionPolicy()
        let peripheral = UUID()
        _ = policy.beginInteractiveSession(for: target)
        guard case let .connect(_, firstGeneration) = policy.receiveAdvertisement(
            peripheralIdentifier: peripheral,
            observedName: target.name
        ) else {
            return XCTFail("Expected the first connection attempt")
        }

        XCTAssertEqual(
            policy.supersedeAfterDisconnect(
                with: target,
                peripheralIdentifier: peripheral
            ),
            .cancelConnection(peripheralIdentifier: peripheral)
        )
        XCTAssertGreaterThan(policy.attemptGeneration, firstGeneration)

        // CoreBluetooth does not return our generation. A late callback from
        // the cancelled request therefore has the exact identifier that the
        // replacement will use and must be rejected by the disconnect barrier.
        XCTAssertEqual(
            policy.receiveConnected(peripheralIdentifier: peripheral),
            .cancelConnection(peripheralIdentifier: peripheral)
        )
        guard case .disconnecting = policy.state else {
            return XCTFail("Replacement must remain pending during cancellation")
        }

        guard case let .startScan(restartedTarget, secondGeneration) =
            policy.receiveDisconnected(peripheralIdentifier: peripheral)
        else {
            return XCTFail("Expected cancellation to launch the replacement")
        }
        XCTAssertEqual(restartedTarget, target)
        XCTAssertGreaterThan(secondGeneration, firstGeneration)
        XCTAssertEqual(
            policy.receiveAdvertisement(
                peripheralIdentifier: peripheral,
                observedName: target.name
            ),
            .connect(
                peripheralIdentifier: peripheral,
                attemptGeneration: secondGeneration
            )
        )
        XCTAssertEqual(
            policy.receiveConnected(peripheralIdentifier: peripheral),
            .discoverServices(
                peripheralIdentifier: peripheral,
                attemptGeneration: secondGeneration
            )
        )
    }

    func testUnexpectedReadyDisconnectSchedulesExactlyOneReconnect() {
        var policy = ProMistBLEConnectionPolicy()
        let peripheral = UUID()
        makeReady(&policy, peripheral: peripheral)

        let action = policy.receiveDisconnected(
            peripheralIdentifier: peripheral
        )
        guard case let .scheduleReconnect(scheduledTarget, generation) = action else {
            return XCTFail("Expected reconnect scheduling")
        }
        XCTAssertEqual(scheduledTarget, target)
        XCTAssertEqual(
            policy.receiveDisconnected(peripheralIdentifier: peripheral),
            .ignore
        )
        guard case .reconnectWaiting = policy.state else {
            return XCTFail("Expected reconnect-waiting state")
        }
        XCTAssertEqual(
            policy.reconnectTimerFired(generation: generation),
            .startScan(
                target: target,
                attemptGeneration: policy.attemptGeneration
            )
        )
    }

    func testAdoptedAddFanLinkBecomesReconnectableInteractiveSession() {
        var policy = ProMistBLEConnectionPolicy()
        let peripheral = UUID()

        policy.adoptReadyInteractiveSession(
            for: target,
            peripheralIdentifier: peripheral
        )

        guard case let .ready(attempt, deviceID) = policy.state else {
            return XCTFail("Expected the authenticated link to be adopted as ready")
        }
        XCTAssertEqual(deviceID, target.deviceID)
        XCTAssertEqual(attempt.target, target)
        XCTAssertEqual(attempt.peripheralIdentifier, peripheral)
        XCTAssertEqual(policy.interactiveTarget, target)
        XCTAssertEqual(policy.requestedTarget, target)
        XCTAssertFalse(policy.reconnectSuppressed)
        XCTAssertEqual(policy.beginInteractiveSession(for: target), .ignore)

        guard case let .scheduleReconnect(reconnectTarget, _) =
            policy.receiveDisconnected(peripheralIdentifier: peripheral)
        else {
            return XCTFail("Expected an adopted interactive link to reconnect")
        }
        XCTAssertEqual(reconnectTarget, target)
    }

    func testInteractiveAttemptTimeoutSchedulesOneReconnect() {
        var policy = ProMistBLEConnectionPolicy()
        _ = policy.beginInteractiveSession(for: target)

        let action = policy.receiveAttemptTimeout("Connection timed out")
        guard case let .scheduleReconnect(scheduledTarget, generation) = action else {
            return XCTFail("Expected reconnect scheduling")
        }
        XCTAssertEqual(scheduledTarget, target)
        XCTAssertEqual(policy.receiveAttemptTimeout("duplicate timeout"), .ignore)
        XCTAssertEqual(policy.reconnectGeneration, generation)
    }

    func testNoninteractiveAttemptTimeoutFailsWithoutReconnect() {
        var policy = ProMistBLEConnectionPolicy()
        _ = policy.beginKnownDeviceResolution(for: target)

        XCTAssertEqual(
            policy.receiveAttemptTimeout("Connection timed out"),
            .ignore
        )
        XCTAssertEqual(policy.state, .failed("Connection timed out"))
    }

    func testExplicitReadyDisconnectNeverSchedulesReconnect() {
        var policy = ProMistBLEConnectionPolicy()
        let peripheral = UUID()
        makeReady(&policy, peripheral: peripheral)

        _ = policy.requestDisconnect(peripheralIdentifier: peripheral)
        XCTAssertEqual(
            policy.receiveDisconnected(peripheralIdentifier: peripheral),
            .ignore
        )
        XCTAssertEqual(policy.state, .idle)
    }

    func testStaleRefreshGenerationCannotPublish() {
        var policy = ProMistBLEConnectionPolicy()
        let first = policy.beginRefresh([target])!
        let secondTarget = ProMistBLEConnectionPolicy.Target(
            deviceID: 0x654321,
            name: "ProMist-654321"
        )
        let second = policy.beginRefresh([secondTarget])!

        XCTAssertFalse(policy.isCurrentRefresh(first.generation))
        XCTAssertFalse(policy.finishRefresh(first.generation))
        XCTAssertTrue(policy.isCurrentRefresh(second.generation))
        XCTAssertTrue(policy.finishRefresh(second.generation))
    }

    func testAdvertisementNeverOverridesFirmwareIdentity() {
        var policy = ProMistBLEConnectionPolicy()
        let peripheral = UUID()
        _ = policy.beginInteractiveSession(for: target)
        _ = policy.receiveAdvertisement(
            peripheralIdentifier: peripheral,
            observedName: target.name
        )
        _ = policy.receiveConnected(peripheralIdentifier: peripheral)

        XCTAssertEqual(
            policy.receiveFirmwareIdentity(
                0x999999,
                peripheralIdentifier: peripheral
            ),
            .rejectMismatch
        )
        XCTAssertEqual(policy.state, .failed("Device identity mismatch"))
    }

    private func makeReady(
        _ policy: inout ProMistBLEConnectionPolicy,
        peripheral: UUID
    ) {
        _ = policy.beginInteractiveSession(for: target)
        _ = policy.receiveAdvertisement(
            peripheralIdentifier: peripheral,
            observedName: target.name
        )
        _ = policy.receiveConnected(peripheralIdentifier: peripheral)
        let decision = policy.receiveFirmwareIdentity(
            target.deviceID,
            peripheralIdentifier: peripheral
        )
        guard case let .authenticate(deviceID, generation) = decision else {
            return XCTFail("Expected authentication")
        }
        XCTAssertTrue(policy.authenticationCompleted(
            deviceID: deviceID,
            attemptGeneration: generation
        ))
    }
}
