import Foundation

/// Owns app-local device lifecycle data and credential-first removal decisions.
/// It returns transport cleanup plans; CoreBluetooth cancellation remains in the
/// central that owns the live peripheral.
@MainActor
final class ProMistLocalDeviceLifecycleCoordinator {
    struct Credentials {
        var delete: (UInt64) throws -> Void
        var deleteAll: ([UInt64]) throws -> Void

        @MainActor
        static var live: Credentials {
            Credentials(
                delete: { try OwnerCredentialStore.delete(deviceID: $0) },
                deleteAll: { try OwnerCredentialStore.deleteAll(deviceIDs: $0) }
            )
        }
    }

    struct ActiveSession: Equatable {
        var requestedDeviceID: UInt64?
        var connectedDeviceID: UInt64
        var selectedPeripheralIdentifier: UUID?
        var interactiveDeviceID: UInt64?
    }

    struct ForgetPlan: Equatable {
        let peripheralIdentifier: UUID?
        let shouldEndInteractiveSession: Bool
        let shouldResetActiveTransport: Bool
    }

    struct PublishedState: Equatable {
        let recoveryRequiredDeviceID: UInt64?
        let ownershipResetCompletedDeviceID: UInt64?
        let sessionSnapshots: [UInt64: ProMistSessionSnapshot]
    }

    private let credentials: Credentials
    private var recoveryRequiredDeviceID: UInt64?
    private var ownershipResetCompletedDeviceID: UInt64?
    private var sessionSnapshots: [UInt64: ProMistSessionSnapshot] = [:]

    var stateChanged: ((PublishedState) -> Void)?

    init(credentials: Credentials = .live) {
        self.credentials = credentials
    }

    var publishedState: PublishedState {
        PublishedState(
            recoveryRequiredDeviceID: recoveryRequiredDeviceID,
            ownershipResetCompletedDeviceID: ownershipResetCompletedDeviceID,
            sessionSnapshots: sessionSnapshots
        )
    }

    func snapshot(
        for deviceID: UInt64,
        at date: Date = .now
    ) -> ProMistSessionSnapshot? {
        guard let snapshot = sessionSnapshots[deviceID],
              snapshot.isFresh(at: date) else { return nil }
        return snapshot
    }

    func recordSnapshot(
        _ state: ProMistDeviceState,
        authenticated: Bool,
        at date: Date = .now
    ) {
        guard authenticated, state.deviceID != 0 else { return }
        sessionSnapshots[state.deviceID] = ProMistSessionSnapshot(
            state: state,
            observedAt: date
        )
        publish()
    }

    func expireSnapshots(at date: Date = .now) {
        sessionSnapshots = sessionSnapshots.filter {
            $0.value.isFresh(at: date)
        }
        publish()
    }

    func requireRecovery(for deviceID: UInt64) {
        recoveryRequiredDeviceID = deviceID
        publish()
    }

    func beginOwnershipReset() {
        ownershipResetCompletedDeviceID = nil
        publish()
    }

    func completeOwnershipReset(for deviceID: UInt64) {
        ownershipResetCompletedDeviceID = deviceID
        publish()
    }

    /// Removes every supplied Keychain credential before clearing published
    /// app-session state. Any credential failure leaves that state intact.
    func resetAll(deviceIDs: [UInt64]) throws {
        try credentials.deleteAll(deviceIDs)
        recoveryRequiredDeviceID = nil
        ownershipResetCompletedDeviceID = nil
        sessionSnapshots.removeAll()
        publish()
    }

    /// Deletes one credential first, then returns the live transport cleanup
    /// needed for the matching device or peripheral.
    ///
    /// - Throws: A credential deletion error before app-visible state changes.
    func forget(
        deviceID: UInt64,
        peripheralIdentifier: UUID?,
        session: ActiveSession
    ) throws -> ForgetPlan {
        // Credential deletion is deliberately first. A Keychain failure must
        // leave every visible/local association available for an idempotent retry.
        try credentials.delete(deviceID)
        sessionSnapshots.removeValue(forKey: deviceID)
        if recoveryRequiredDeviceID == deviceID {
            recoveryRequiredDeviceID = nil
        }
        publish()

        let matchesPeripheral = peripheralIdentifier != nil &&
            session.selectedPeripheralIdentifier == peripheralIdentifier
        return ForgetPlan(
            peripheralIdentifier: peripheralIdentifier,
            shouldEndInteractiveSession: session.interactiveDeviceID == deviceID,
            shouldResetActiveTransport: session.requestedDeviceID == deviceID ||
                session.connectedDeviceID == deviceID || matchesPeripheral
        )
    }

    private func publish() {
        stateChanged?(publishedState)
    }
}
