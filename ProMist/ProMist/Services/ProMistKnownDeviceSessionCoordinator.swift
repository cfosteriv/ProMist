import Foundation

/// Owns known-device policy execution, refresh/reconnect tasks, and bounded
/// state/information read retries. CoreBluetooth objects stay in the central;
/// this coordinator schedules work and emits transport actions through seams.
@MainActor
final class ProMistKnownDeviceSessionCoordinator {
    typealias Target = ProMistBLEConnectionPolicy.Target
    typealias Action = ProMistBLEConnectionPolicy.Action

    enum ReadKind: Hashable, Sendable {
        case state
        case information
    }

    struct Dependencies {
        var executeAction: (Action) -> Void
        var startRefreshConnection: (Target) -> Void
        var connectionState: () -> ProMistConnectionState
        var finishRefreshAttempt: (UInt64) async -> Void
        var refreshStateChanged: (Bool) -> Void
        var trace: (String) -> Void
    }

    private var policy = ProMistBLEConnectionPolicy()
    private let dependencies: Dependencies
    private let reconnectDelay: Duration
    private let refreshPollInterval: Duration
    private let refreshPollLimit: Int
    private let refreshSettleDelay: Duration
    private let readResponseDelay: Duration

    private var reconnectTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?
    private var queuedRefreshTargets: [Target] = []
    private var readTasks: [ReadKind: Task<Void, Never>] = [:]
    private var readAttempts: [ReadKind: Int] = [:]

    init(
        dependencies: Dependencies,
        reconnectDelay: Duration = .milliseconds(350),
        refreshPollInterval: Duration = .milliseconds(250),
        refreshPollLimit: Int = 32,
        refreshSettleDelay: Duration = .milliseconds(250),
        readResponseDelay: Duration = .seconds(1)
    ) {
        self.dependencies = dependencies
        self.reconnectDelay = reconnectDelay
        self.refreshPollInterval = refreshPollInterval
        self.refreshPollLimit = refreshPollLimit
        self.refreshSettleDelay = refreshSettleDelay
        self.readResponseDelay = readResponseDelay
    }

    var interactiveTarget: Target? { policy.interactiveTarget }
    var attemptGeneration: UInt64 { policy.attemptGeneration }
    var hasActiveRefresh: Bool {
        refreshTask != nil || !queuedRefreshTargets.isEmpty ||
            policy.activeRefresh != nil
    }

    func hasActiveAttempt(for target: Target) -> Bool {
        policy.hasActiveAttempt(for: target)
    }

    func reset(bluetoothAvailable: Bool) {
        cancelReconnect()
        cancelRefresh()
        cancelAllReads()
        policy.reset(bluetoothAvailable: bluetoothAvailable)
    }

    func bluetoothAvailabilityChanged(isAvailable: Bool) {
        policy.bluetoothAvailabilityChanged(isAvailable: isAvailable)
    }

    func beginInteractiveSession(for target: Target) -> Action {
        policy.beginInteractiveSession(for: target)
    }

    func adoptReadyInteractiveSession(
        for target: Target,
        peripheralIdentifier: UUID?
    ) {
        cancelReconnect()
        policy.adoptReadyInteractiveSession(
            for: target,
            peripheralIdentifier: peripheralIdentifier
        )
    }

    func endInteractiveSession(deviceID: UInt64) {
        policy.endInteractiveSession(deviceID: deviceID)
        cancelReconnect()
    }

    func beginKnownDeviceResolution(for target: Target) -> Action {
        policy.beginKnownDeviceResolution(for: target)
    }

    func supersedeAfterDisconnect(
        with target: Target,
        peripheralIdentifier: UUID
    ) -> Action {
        policy.supersedeAfterDisconnect(
            with: target,
            peripheralIdentifier: peripheralIdentifier
        )
    }

    func requestDisconnect(peripheralIdentifier: UUID?) -> Action {
        cancelReconnect()
        return policy.requestDisconnect(
            peripheralIdentifier: peripheralIdentifier
        )
    }

    func receiveAdvertisement(
        peripheralIdentifier: UUID,
        observedName: String
    ) -> Action {
        policy.receiveAdvertisement(
            peripheralIdentifier: peripheralIdentifier,
            observedName: observedName
        )
    }

    func receiveConnected(peripheralIdentifier: UUID) -> Action {
        policy.receiveConnected(peripheralIdentifier: peripheralIdentifier)
    }

    func receiveDisconnected(peripheralIdentifier: UUID) -> Action {
        policy.receiveDisconnected(peripheralIdentifier: peripheralIdentifier)
    }

    func receiveFirmwareIdentity(
        _ deviceID: UInt64,
        peripheralIdentifier: UUID
    ) -> ProMistBLEConnectionPolicy.IdentityDecision {
        policy.receiveFirmwareIdentity(
            deviceID,
            peripheralIdentifier: peripheralIdentifier
        )
    }

    func authenticationCompleted(deviceID: UInt64) -> Bool {
        policy.authenticationCompleted(
            deviceID: deviceID,
            attemptGeneration: policy.attemptGeneration
        )
    }

    func receiveAttemptTimeout(_ message: String) -> Action {
        policy.receiveAttemptTimeout(message)
    }

    func failCurrentAttempt(_ message: String) {
        policy.failCurrentAttempt(message)
    }

    /// Executes policy actions and owns delayed reconnect generations. All
    /// immediate CoreBluetooth work is routed back to the central.
    func execute(_ action: Action) {
        guard case let .scheduleReconnect(target, generation) = action else {
            dependencies.executeAction(action)
            return
        }
        reconnectTask?.cancel()
        reconnectTask = Task { @MainActor [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: self.reconnectDelay)
            guard !Task.isCancelled else { return }
            self.reconnectTask = nil
            self.execute(
                self.policy.reconnectTimerFired(generation: generation)
            )
        }
        dependencies.trace(
            "Unexpected disconnect; reconnect scheduled name=\(target.name)"
        )
    }

    func cancelReconnect() {
        reconnectTask?.cancel()
        reconnectTask = nil
    }

    func startRefresh(_ targets: [Target], allowed: Bool) {
        cancelRefresh()
        guard allowed else { return }
        var seenDeviceIDs = Set<UInt64>()
        let uniqueTargets = targets.filter {
            seenDeviceIDs.insert($0.deviceID).inserted
        }
        guard !uniqueTargets.isEmpty,
              let refresh = policy.beginRefresh(uniqueTargets) else { return }
        queuedRefreshTargets = refresh.targets
        dependencies.trace(
            "Known fan refresh queued count=\(uniqueTargets.count)"
        )
    }

    @discardableResult
    func cancelRefresh() -> Bool {
        let hadRefresh = hasActiveRefresh
        guard hadRefresh else { return false }
        policy.cancelRefresh()
        refreshTask?.cancel()
        refreshTask = nil
        queuedRefreshTargets.removeAll()
        dependencies.refreshStateChanged(false)
        return true
    }

    func removeRefreshTarget(deviceID: UInt64) {
        queuedRefreshTargets.removeAll { $0.deviceID == deviceID }
    }

    func beginRefreshIfPossible(bluetoothAvailable: Bool) {
        guard bluetoothAvailable,
              refreshTask == nil,
              !queuedRefreshTargets.isEmpty,
              let refresh = policy.activeRefresh else { return }

        let targets = queuedRefreshTargets
        queuedRefreshTargets.removeAll()
        let generation = refresh.generation
        dependencies.refreshStateChanged(true)
        dependencies.trace("Known fan refresh started count=\(targets.count)")

        refreshTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if self.policy.finishRefresh(generation) {
                    self.refreshTask = nil
                    self.dependencies.refreshStateChanged(false)
                    self.dependencies.trace("Known fan refresh finished")
                }
            }

            for (index, target) in targets.enumerated() {
                guard !Task.isCancelled,
                      self.policy.isCurrentRefresh(generation) else { return }
                self.dependencies.trace(
                    "Known fan refresh attempt=\(index + 1)/\(targets.count) name=\(target.name) device=\(target.deviceID)"
                )
                self.dependencies.startRefreshConnection(target)
                let refreshed = await self.waitForReady(generation: generation)
                guard !Task.isCancelled,
                      self.policy.isCurrentRefresh(generation) else { return }
                self.dependencies.trace(
                    "Known fan refresh \(refreshed ? "succeeded" : "timed out/failed") name=\(target.name)"
                )
                if refreshed {
                    try? await Task.sleep(for: self.refreshSettleDelay)
                }
                guard !Task.isCancelled else { return }
                let keepConnection = refreshed && index == targets.count - 1
                if keepConnection {
                    self.dependencies.trace(
                        "Known fan refresh retaining active connection name=\(target.name)"
                    )
                } else {
                    await self.dependencies.finishRefreshAttempt(generation)
                }
            }
        }
    }

    func isCurrentRefresh(_ generation: UInt64) -> Bool {
        policy.isCurrentRefresh(generation)
    }

    func requestRead(
        _ kind: ReadKind,
        afterNanoseconds delay: UInt64 = 0,
        maximumAttempts: Int = 3,
        shouldRun: @escaping () -> Bool,
        perform: @escaping (_ attempt: Int) -> Void,
        exhausted: @escaping () -> Void
    ) {
        let attempts = readAttempts[kind, default: 0]
        guard shouldRun(), attempts < maximumAttempts else { return }
        readTasks.removeValue(forKey: kind)?.cancel()
        let attempt = attempts + 1
        readAttempts[kind] = attempt
        readTasks[kind] = Task { @MainActor [weak self] in
            if delay > 0 {
                try? await Task.sleep(nanoseconds: delay)
            }
            guard !Task.isCancelled, let self, shouldRun() else { return }
            perform(attempt)
            try? await Task.sleep(for: self.readResponseDelay)
            guard !Task.isCancelled, shouldRun() else { return }
            if self.readAttempts[kind, default: 0] < maximumAttempts {
                self.requestRead(
                    kind,
                    maximumAttempts: maximumAttempts,
                    shouldRun: shouldRun,
                    perform: perform,
                    exhausted: exhausted
                )
            } else {
                exhausted()
            }
        }
    }

    func cancelRead(_ kind: ReadKind) {
        readTasks.removeValue(forKey: kind)?.cancel()
        readAttempts[kind] = 0
    }

    func isReadScheduled(_ kind: ReadKind) -> Bool {
        readTasks[kind] != nil
    }

    func cancelAllReads() {
        readTasks.values.forEach { $0.cancel() }
        readTasks.removeAll()
        readAttempts.removeAll()
    }

    private func waitForReady(generation: UInt64) async -> Bool {
        for _ in 0..<refreshPollLimit {
            guard !Task.isCancelled,
                  policy.isCurrentRefresh(generation) else { return false }
            switch dependencies.connectionState() {
            case .ready:
                return true
            case .failed:
                return false
            case .bluetoothUnavailable, .idle, .scanning, .connecting,
                 .discovering:
                break
            }
            try? await Task.sleep(for: refreshPollInterval)
        }
        return false
    }
}
