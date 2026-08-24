import XCTest
@testable import ProMist

@MainActor
final class ProMistLocalDeviceLifecycleCoordinatorTests: XCTestCase {
    private enum TestFailure: Error { case keychain }

    func testSnapshotsAreAuthenticatedFreshAndExpirable() {
        let coordinator = makeCoordinator()
        var state = ProMistDeviceState()
        state.deviceID = 42
        let observedAt = Date(timeIntervalSince1970: 1_000)

        coordinator.recordSnapshot(state, authenticated: false, at: observedAt)
        XCTAssertNil(coordinator.snapshot(for: 42, at: observedAt))

        coordinator.recordSnapshot(state, authenticated: true, at: observedAt)
        XCTAssertEqual(
            coordinator.snapshot(for: 42, at: observedAt)?.state.deviceID,
            42
        )
        coordinator.expireSnapshots(
            at: observedAt.addingTimeInterval(
                ProMistSessionSnapshot.maximumAge + 1
            )
        )
        XCTAssertTrue(coordinator.publishedState.sessionSnapshots.isEmpty)
    }

    func testForgetDeletesCredentialBeforeChangingLifecycleState() throws {
        var deleted: [UInt64] = []
        let peripheralID = UUID()
        let coordinator = makeCoordinator(delete: { deleted.append($0) })
        coordinator.requireRecovery(for: 42)

        let plan = try coordinator.forget(
            deviceID: 42,
            peripheralIdentifier: peripheralID,
            session: .init(
                requestedDeviceID: 42,
                connectedDeviceID: 0,
                selectedPeripheralIdentifier: peripheralID,
                interactiveDeviceID: 42
            )
        )

        XCTAssertEqual(deleted, [42])
        XCTAssertTrue(plan.shouldEndInteractiveSession)
        XCTAssertTrue(plan.shouldResetActiveTransport)
        XCTAssertNil(coordinator.publishedState.recoveryRequiredDeviceID)
    }

    func testCredentialFailureLeavesLocalLifecycleUntouched() {
        let coordinator = makeCoordinator(delete: { _ in throw TestFailure.keychain })
        coordinator.requireRecovery(for: 42)

        XCTAssertThrowsError(try coordinator.forget(
            deviceID: 42,
            peripheralIdentifier: nil,
            session: .init(
                requestedDeviceID: nil,
                connectedDeviceID: 0,
                selectedPeripheralIdentifier: nil,
                interactiveDeviceID: nil
            )
        ))
        XCTAssertEqual(coordinator.publishedState.recoveryRequiredDeviceID, 42)
    }

    func testResetAllClearsPublishedOwnershipAndSnapshotState() throws {
        var resetIDs: [UInt64] = []
        let coordinator = makeCoordinator(deleteAll: { resetIDs = $0 })
        var state = ProMistDeviceState()
        state.deviceID = 42
        coordinator.recordSnapshot(state, authenticated: true)
        coordinator.requireRecovery(for: 42)
        coordinator.completeOwnershipReset(for: 42)

        try coordinator.resetAll(deviceIDs: [42, 43])

        XCTAssertEqual(resetIDs, [42, 43])
        XCTAssertEqual(
            coordinator.publishedState,
            .init(
                recoveryRequiredDeviceID: nil,
                ownershipResetCompletedDeviceID: nil,
                sessionSnapshots: [:]
            )
        )
    }

    private func makeCoordinator(
        delete: @escaping (UInt64) throws -> Void = { _ in },
        deleteAll: @escaping ([UInt64]) throws -> Void = { _ in }
    ) -> ProMistLocalDeviceLifecycleCoordinator {
        ProMistLocalDeviceLifecycleCoordinator(
            credentials: .init(delete: delete, deleteAll: deleteAll)
        )
    }
}
