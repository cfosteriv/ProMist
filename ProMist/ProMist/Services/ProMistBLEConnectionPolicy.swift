import Foundation

/// Pure connection/reconnect policy. CoreBluetooth remains owned exclusively by
/// `ProMistBLECentral`; this type validates lifecycle events and returns actions
/// for that coordinator to execute.
///
/// Invariants:
/// - only the current attempt generation may advance toward readiness;
/// - a firmware-reported device ID, never an advertisement or CB UUID, is the
///   authoritative saved-device identity;
/// - an explicit disconnect suppresses automatic reconnect;
/// - a replacement attempt cannot start until cancellation of the superseded
///   CoreBluetooth request reaches a terminal callback, even when both attempts
///   resolve to the same `CBPeripheral.identifier`;
/// - a reconnect generation is scheduled at most once;
/// - a superseded refresh generation can never publish a result.
struct ProMistBLEConnectionPolicy {
    struct Target: Equatable, Sendable {
        let deviceID: UInt64
        let name: String
    }

    struct Attempt: Equatable, Sendable {
        let generation: UInt64
        let target: Target
        let peripheralIdentifier: UUID?
    }

    enum State: Equatable, Sendable {
        case bluetoothUnavailable
        case idle
        case resolving(Attempt)
        case connecting(Attempt)
        case discovering(Attempt)
        case authenticating(Attempt, deviceID: UInt64)
        case ready(Attempt, deviceID: UInt64)
        case disconnecting(Attempt?, userRequested: Bool)
        case reconnectWaiting(Target, generation: UInt64)
        case failed(String)
    }

    enum Action: Equatable, Sendable {
        case startScan(target: Target, attemptGeneration: UInt64)
        case stopScan
        case connect(peripheralIdentifier: UUID, attemptGeneration: UInt64)
        case cancelConnection(peripheralIdentifier: UUID)
        case discoverServices(peripheralIdentifier: UUID, attemptGeneration: UInt64)
        case scheduleReconnect(target: Target, reconnectGeneration: UInt64)
        case ignore
    }

    struct Refresh: Equatable, Sendable {
        let generation: UInt64
        let targets: [Target]
    }

    private(set) var state: State = .idle
    private(set) var interactiveTarget: Target?
    private(set) var requestedTarget: Target?
    private(set) var selectedPeripheralIdentifier: UUID?
    private(set) var attemptGeneration: UInt64 = 0
    private(set) var reconnectGeneration: UInt64 = 0
    private(set) var refreshGeneration: UInt64 = 0
    private(set) var activeRefresh: Refresh?
    private(set) var reconnectSuppressed = true

    private var pendingTargetAfterDisconnect: Target?

    var userRequestedDisconnect: Bool {
        if case .disconnecting(_, userRequested: true) = state { return true }
        return false
    }

    func hasActiveAttempt(for target: Target) -> Bool {
        guard requestedTarget == target else { return false }
        switch state {
        case .resolving, .connecting, .discovering, .authenticating:
            return true
        case let .ready(_, deviceID):
            return deviceID == target.deviceID
        case let .reconnectWaiting(waitingTarget, _):
            return waitingTarget == target
        case .bluetoothUnavailable, .idle, .disconnecting, .failed:
            return false
        }
    }

    mutating func bluetoothAvailabilityChanged(isAvailable: Bool) {
        guard isAvailable else {
            invalidateAttempt()
            state = .bluetoothUnavailable
            return
        }
        if state == .bluetoothUnavailable { state = .idle }
    }

    mutating func reset(bluetoothAvailable: Bool = true) {
        attemptGeneration &+= 1
        reconnectGeneration &+= 1
        refreshGeneration &+= 1
        interactiveTarget = nil
        requestedTarget = nil
        selectedPeripheralIdentifier = nil
        activeRefresh = nil
        pendingTargetAfterDisconnect = nil
        reconnectSuppressed = true
        state = bluetoothAvailable ? .idle : .bluetoothUnavailable
    }

    @discardableResult
    mutating func beginInteractiveSession(for target: Target) -> Action {
        interactiveTarget = target
        reconnectSuppressed = false
        guard !hasActiveAttempt(for: target) else { return .ignore }
        return beginKnownDeviceResolution(for: target)
    }

    /// Promotes an authenticated link that originated in the Add Fan flow into
    /// the known-device state machine. Discovery connections intentionally do
    /// not have a requested target until firmware identity is verified, so the
    /// first device-screen session must adopt that link instead of starting (or
    /// accidentally latching) an unexecuted resolution attempt.
    mutating func adoptReadyInteractiveSession(
        for target: Target,
        peripheralIdentifier: UUID?
    ) {
        attemptGeneration &+= 1
        if attemptGeneration == 0 { attemptGeneration = 1 }
        reconnectGeneration &+= 1
        if reconnectGeneration == 0 { reconnectGeneration = 1 }
        interactiveTarget = target
        requestedTarget = target
        selectedPeripheralIdentifier = peripheralIdentifier
        pendingTargetAfterDisconnect = nil
        reconnectSuppressed = false
        state = .ready(
            Attempt(
                generation: attemptGeneration,
                target: target,
                peripheralIdentifier: peripheralIdentifier
            ),
            deviceID: target.deviceID
        )
    }

    mutating func endInteractiveSession(deviceID: UInt64) {
        guard interactiveTarget?.deviceID == deviceID else { return }
        interactiveTarget = nil
        reconnectSuppressed = true
        if case .reconnectWaiting = state {
            invalidateAttempt()
            requestedTarget = nil
            state = .idle
        }
    }

    @discardableResult
    mutating func beginKnownDeviceResolution(for target: Target) -> Action {
        attemptGeneration &+= 1
        if attemptGeneration == 0 { attemptGeneration = 1 }
        requestedTarget = target
        selectedPeripheralIdentifier = nil
        pendingTargetAfterDisconnect = nil
        let attempt = Attempt(
            generation: attemptGeneration,
            target: target,
            peripheralIdentifier: nil
        )
        state = .resolving(attempt)
        return .startScan(target: target, attemptGeneration: attemptGeneration)
    }

    /// An advertised name may select a connection candidate, but it never
    /// authenticates identity. `receiveFirmwareIdentity` performs that check.
    mutating func receiveAdvertisement(
        peripheralIdentifier: UUID,
        observedName: String
    ) -> Action {
        guard case let .resolving(attempt) = state,
              ProMistBLEProtocol.advertisementNameMatches(
                  observedName: observedName,
                  expectedName: attempt.target.name,
                  deviceID: attempt.target.deviceID
              ) else { return .ignore }
        let selectedAttempt = Attempt(
            generation: attempt.generation,
            target: attempt.target,
            peripheralIdentifier: peripheralIdentifier
        )
        selectedPeripheralIdentifier = peripheralIdentifier
        state = .connecting(selectedAttempt)
        return .connect(
            peripheralIdentifier: peripheralIdentifier,
            attemptGeneration: attempt.generation
        )
    }

    mutating func receiveConnected(peripheralIdentifier: UUID) -> Action {
        if case .disconnecting = state {
            return .cancelConnection(peripheralIdentifier: peripheralIdentifier)
        }
        guard case let .connecting(attempt) = state,
              attempt.generation == attemptGeneration,
              attempt.peripheralIdentifier == peripheralIdentifier,
              selectedPeripheralIdentifier == peripheralIdentifier
        else {
            return .cancelConnection(peripheralIdentifier: peripheralIdentifier)
        }
        state = .discovering(attempt)
        return .discoverServices(
            peripheralIdentifier: peripheralIdentifier,
            attemptGeneration: attempt.generation
        )
    }

    enum IdentityDecision: Equatable, Sendable {
        case authenticate(deviceID: UInt64, attemptGeneration: UInt64)
        case rejectMismatch
        case ignoreStale
    }

    mutating func receiveFirmwareIdentity(
        _ deviceID: UInt64,
        peripheralIdentifier: UUID
    ) -> IdentityDecision {
        guard case let .discovering(attempt) = state,
              attempt.generation == attemptGeneration,
              attempt.peripheralIdentifier == peripheralIdentifier,
              selectedPeripheralIdentifier == peripheralIdentifier
        else { return .ignoreStale }
        guard deviceID != 0, deviceID == attempt.target.deviceID else {
            state = .failed("Device identity mismatch")
            return .rejectMismatch
        }
        state = .authenticating(attempt, deviceID: deviceID)
        return .authenticate(
            deviceID: deviceID,
            attemptGeneration: attempt.generation
        )
    }

    @discardableResult
    mutating func authenticationCompleted(
        deviceID: UInt64,
        attemptGeneration: UInt64
    ) -> Bool {
        guard case let .authenticating(attempt, authenticatingDeviceID) = state,
              attempt.generation == attemptGeneration,
              attempt.generation == self.attemptGeneration,
              authenticatingDeviceID == deviceID,
              attempt.target.deviceID == deviceID
        else { return false }
        state = .ready(attempt, deviceID: deviceID)
        return true
    }

    mutating func failCurrentAttempt(_ message: String) {
        invalidateAttempt()
        state = .failed(message)
    }

    mutating func requestDisconnect(
        peripheralIdentifier: UUID?
    ) -> Action {
        reconnectSuppressed = true
        interactiveTarget = nil
        requestedTarget = nil
        pendingTargetAfterDisconnect = nil
        reconnectGeneration &+= 1
        let attempt = currentAttempt
        invalidateAttempt(keepingPeripheral: true)
        guard let peripheralIdentifier else {
            selectedPeripheralIdentifier = nil
            state = .idle
            return .stopScan
        }
        selectedPeripheralIdentifier = peripheralIdentifier
        state = .disconnecting(attempt, userRequested: true)
        return .cancelConnection(peripheralIdentifier: peripheralIdentifier)
    }

    /// Used when the coordinator must tear down an old link before starting a
    /// superseding connection. The new attempt is not active until disconnect;
    /// this serialization is the generation boundary when CoreBluetooth reuses
    /// the same peripheral identifier and cannot return an app attempt token.
    mutating func supersedeAfterDisconnect(
        with target: Target,
        peripheralIdentifier: UUID
    ) -> Action {
        pendingTargetAfterDisconnect = target
        reconnectSuppressed = false
        requestedTarget = target
        invalidateAttempt(keepingPeripheral: true)
        selectedPeripheralIdentifier = peripheralIdentifier
        state = .disconnecting(currentAttempt, userRequested: false)
        return .cancelConnection(peripheralIdentifier: peripheralIdentifier)
    }

    mutating func receiveDisconnected(
        peripheralIdentifier: UUID
    ) -> Action {
        guard selectedPeripheralIdentifier == peripheralIdentifier else {
            return .ignore
        }

        if let pendingTargetAfterDisconnect {
            self.pendingTargetAfterDisconnect = nil
            selectedPeripheralIdentifier = nil
            return beginKnownDeviceResolution(for: pendingTargetAfterDisconnect)
        }

        let wasReady: Bool
        if case .ready = state { wasReady = true } else { wasReady = false }
        let wasExplicit = userRequestedDisconnect
        selectedPeripheralIdentifier = nil

        if wasExplicit {
            state = .idle
            return .ignore
        }

        guard wasReady,
              !reconnectSuppressed,
              let target = interactiveTarget,
              target == requestedTarget
        else {
            state = .failed("Disconnected")
            return .ignore
        }

        reconnectGeneration &+= 1
        if reconnectGeneration == 0 { reconnectGeneration = 1 }
        state = .reconnectWaiting(target, generation: reconnectGeneration)
        return .scheduleReconnect(
            target: target,
            reconnectGeneration: reconnectGeneration
        )
    }

    mutating func reconnectTimerFired(generation: UInt64) -> Action {
        guard case let .reconnectWaiting(target, currentGeneration) = state,
              currentGeneration == generation,
              reconnectGeneration == generation,
              interactiveTarget == target,
              !reconnectSuppressed
        else { return .ignore }
        return beginKnownDeviceResolution(for: target)
    }

    /// Converts a coordinator-owned timeout into a policy decision. The
    /// coordinator supplies the clock; this state machine alone decides whether
    /// the failed attempt is eligible for the single automatic reconnect.
    mutating func receiveAttemptTimeout(_ message: String) -> Action {
        guard currentAttempt != nil else { return .ignore }
        let target = requestedTarget
        invalidateAttempt()
        guard let target,
              !reconnectSuppressed,
              interactiveTarget == target
        else {
            state = .failed(message)
            return .ignore
        }

        reconnectGeneration &+= 1
        if reconnectGeneration == 0 { reconnectGeneration = 1 }
        state = .reconnectWaiting(target, generation: reconnectGeneration)
        return .scheduleReconnect(
            target: target,
            reconnectGeneration: reconnectGeneration
        )
    }

    mutating func beginRefresh(_ targets: [Target]) -> Refresh? {
        var seen = Set<UInt64>()
        let unique = targets.filter { seen.insert($0.deviceID).inserted }
        cancelRefresh()
        guard !unique.isEmpty else { return nil }
        refreshGeneration &+= 1
        if refreshGeneration == 0 { refreshGeneration = 1 }
        let refresh = Refresh(generation: refreshGeneration, targets: unique)
        activeRefresh = refresh
        return refresh
    }

    mutating func cancelRefresh() {
        refreshGeneration &+= 1
        activeRefresh = nil
    }

    func isCurrentRefresh(_ generation: UInt64) -> Bool {
        activeRefresh?.generation == generation && refreshGeneration == generation
    }

    mutating func finishRefresh(_ generation: UInt64) -> Bool {
        guard isCurrentRefresh(generation) else { return false }
        activeRefresh = nil
        return true
    }

    private var currentAttempt: Attempt? {
        switch state {
        case let .resolving(attempt), let .connecting(attempt),
             let .discovering(attempt), let .authenticating(attempt, _),
             let .ready(attempt, _):
            return attempt
        case let .disconnecting(attempt, _):
            return attempt
        case .bluetoothUnavailable, .idle, .reconnectWaiting, .failed:
            return nil
        }
    }

    private mutating func invalidateAttempt(keepingPeripheral: Bool = false) {
        attemptGeneration &+= 1
        if !keepingPeripheral { selectedPeripheralIdentifier = nil }
    }
}
