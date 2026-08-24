import XCTest
@testable import ProMist

@MainActor
final class ProMistKnownDeviceSessionCoordinatorTests: XCTestCase {
    func testReconnectExecutesOnlyCurrentGeneration() async {
        var actions: [ProMistBLEConnectionPolicy.Action] = []
        let target = ProMistBLEConnectionPolicy.Target(deviceID: 42, name: "Fan")
        let coordinator = makeCoordinator(actions: { actions.append($0) })
        let peripheral = UUID()
        _ = coordinator.beginInteractiveSession(for: target)
        _ = coordinator.receiveAdvertisement(
            peripheralIdentifier: peripheral,
            observedName: target.name
        )
        _ = coordinator.receiveConnected(peripheralIdentifier: peripheral)
        guard case .authenticate = coordinator.receiveFirmwareIdentity(
            target.deviceID,
            peripheralIdentifier: peripheral
        ) else { return XCTFail("Expected identity authentication") }
        XCTAssertTrue(coordinator.authenticationCompleted(
            deviceID: target.deviceID
        ))
        let reconnect = coordinator.receiveDisconnected(
            peripheralIdentifier: peripheral
        )

        coordinator.execute(reconnect)
        coordinator.execute(reconnect)
        try? await Task.sleep(for: .milliseconds(30))

        XCTAssertEqual(actions.count, 1)
        guard case let .startScan(scannedTarget, _) = actions[0] else {
            return XCTFail("Expected one reconnect scan")
        }
        XCTAssertEqual(scannedTarget, target)
    }

    func testRefreshDeduplicatesTargetsAndRetainsFinalReadyConnection() async {
        var started: [UInt64] = []
        var refreshingStates: [Bool] = []
        let state = ProMistConnectionState.ready
        let coordinator = makeCoordinator(
            startRefresh: { started.append($0.deviceID) },
            state: { state },
            refreshing: { refreshingStates.append($0) }
        )
        let first = ProMistBLEConnectionPolicy.Target(deviceID: 1, name: "One")
        let second = ProMistBLEConnectionPolicy.Target(deviceID: 2, name: "Two")

        coordinator.startRefresh([first, first, second], allowed: true)
        coordinator.beginRefreshIfPossible(bluetoothAvailable: true)
        try? await Task.sleep(for: .milliseconds(50))

        XCTAssertEqual(started, [1, 2])
        XCTAssertEqual(refreshingStates.first, true)
        XCTAssertEqual(refreshingStates.last, false)
    }

    func testReadRetryStopsAtConfiguredAttemptLimit() async {
        var attempts: [Int] = []
        var exhausted = false
        let coordinator = makeCoordinator()

        coordinator.requestRead(
            .information,
            maximumAttempts: 3,
            shouldRun: { true },
            perform: { attempts.append($0) },
            exhausted: { exhausted = true }
        )
        try? await Task.sleep(for: .milliseconds(60))

        XCTAssertEqual(attempts, [1, 2, 3])
        XCTAssertTrue(exhausted)
    }

    func testCancelledReadDoesNotRetry() async {
        var attempts = 0
        let coordinator = makeCoordinator()
        coordinator.requestRead(
            .state,
            maximumAttempts: 3,
            shouldRun: { true },
            perform: { _ in attempts += 1 },
            exhausted: {}
        )
        coordinator.cancelRead(.state)
        try? await Task.sleep(for: .milliseconds(30))

        XCTAssertEqual(attempts, 0)
        XCTAssertFalse(coordinator.isReadScheduled(.state))
    }

    private func makeCoordinator(
        actions: @escaping (ProMistBLEConnectionPolicy.Action) -> Void = { _ in },
        startRefresh: @escaping (ProMistBLEConnectionPolicy.Target) -> Void = { _ in },
        state: @escaping () -> ProMistConnectionState = { .idle },
        refreshing: @escaping (Bool) -> Void = { _ in }
    ) -> ProMistKnownDeviceSessionCoordinator {
        ProMistKnownDeviceSessionCoordinator(
            dependencies: .init(
                executeAction: actions,
                startRefreshConnection: startRefresh,
                connectionState: state,
                finishRefreshAttempt: { _ in },
                refreshStateChanged: refreshing,
                trace: { _ in }
            ),
            reconnectDelay: .milliseconds(10),
            refreshPollInterval: .milliseconds(1),
            refreshPollLimit: 3,
            refreshSettleDelay: .milliseconds(1),
            readResponseDelay: .milliseconds(5)
        )
    }
}
