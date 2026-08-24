// Main-actor CoreBluetooth lifecycle owner. It translates delegate callbacks
// into authenticated, request-correlated operations and observable app state.
import Foundation
import Observation
import os
@preconcurrency import CoreBluetooth

@Observable
@MainActor
final class ProMistBLECentral: NSObject {
    /// Process-wide CoreBluetooth owner used by both foreground composition and
    /// cold App Intent resolution. Tests use the transport/policy seams instead
    /// of constructing a second production stack.
    static let shared = ProMistBLECentral()

    /// Lightweight scan result. It is intentionally not a trusted identity;
    /// identity is established only after reading the firmware information.
    struct DiscoveredFan: Identifiable, Equatable {
        let id: UUID
        let name: String
        let rssi: Int
    }

    typealias KnownFanTarget = ProMistBLEConnectionPolicy.Target

    // Module-internal so the same-type CoreBluetooth extensions can share
    // transport state across files. These symbols do not leave the app module.
    var connectionState: ProMistConnectionState = .idle {
        didSet { publishControlSessionStatus() }
    }
    var capabilities: ProMistCapabilities = .none
    var deviceState = ProMistDeviceState() {
        didSet { publishControlSessionStatus() }
    }
    var diagnostics: [ProMistDiagnostic] = []
    var fanBreezeSlots: [BreezePreset?] = [nil, nil, nil]
    var discoveredName = "ProMist"
    var lastResponse: ProMistBLEProtocol.Result?
    var lastResponseRequestID: UInt32?
    var discoveredFans: [DiscoveredFan] = []
    var selectedPeripheralIdentifier: UUID?
    var requestedDeviceID: UInt64?
    private(set) var isRefreshingKnownFans = false
    private(set) var activeDeviceOperationCount = 0
    private(set) var isAuthenticated = false {
        didSet { publishControlSessionStatus() }
    }
    private(set) var recoveryRequiredDeviceID: UInt64?
    private(set) var ownershipResetCompletedDeviceID: UInt64?
    private(set) var sessionSnapshots: [UInt64: ProMistSessionSnapshot] = [:]
    private(set) var isMatterCommissioningHandoff = false

    var isDeviceIOInProgress: Bool {
        activeDeviceOperationCount > 0 || {
            switch connectionState {
            case .scanning, .connecting, .discovering:
                true
            case .bluetoothUnavailable, .idle, .ready, .failed:
                false
            }
        }()
    }

    var supportsCustomBreezeSlots: Bool {
        ProMistBLEProtocol.breezeSlots.allSatisfy { characteristics[$0] != nil }
    }

    private(set) var central: CBCentralManager!
    var peripheral: CBPeripheral?
    var nearbyPeripherals: [UUID: CBPeripheral] = [:]
    var characteristics: [CBUUID: CBCharacteristic] = [:]
    var gattProfile: ProMistGATTProfile = .unresolved
    var deviceInformation: ProMistDeviceInformation?
    var supportsRequiredSessionCharacteristics = false
    var sessionState = ProMistBLESessionState()
    @ObservationIgnored private(set) var knownDeviceCoordinator:
        ProMistKnownDeviceSessionCoordinator!
    @ObservationIgnored let authenticationEngine =
        ProMistBLEAuthenticationEngine()
    @ObservationIgnored let operationTracker =
        ProMistDeviceOperationTracker()
    @ObservationIgnored let localDeviceLifecycle =
        ProMistLocalDeviceLifecycleCoordinator()
    @ObservationIgnored private(set) var matterCoordinator:
        ProMistMatterCommissioningCoordinator!
    @ObservationIgnored private(set) var applianceOperations:
        ProMistApplianceOperationCoordinator!
    @ObservationIgnored private(set) var protocolTransport:
        CoreBluetoothBLETransport?
    @ObservationIgnored private(set) var commandEngine:
        ProMistBLECommandEngine?
    @ObservationIgnored private(set) var diagnosticEngine:
        ProMistDiagnosticsEngine?
    var sessionReachedReady = false
    @ObservationIgnored var pendingKnownFanName: String?
    @ObservationIgnored var connectionAfterDisconnect: (
        deviceID: UInt64?,
        name: String
    )?
    @ObservationIgnored var userRequestedDisconnect = false
    @ObservationIgnored private var connectionTimeoutTask: Task<Void, Never>?
    @ObservationIgnored var diagnosticRefreshRequested = false
    @ObservationIgnored private(set) lazy var deviceSessionCoordinator =
        ProMistDeviceSessionCoordinator(backend: self)
    @ObservationIgnored var controlSessionEventHandler: ((
        UInt64,
        ProMistDeviceSessionStatus
    ) -> Void)?
    @ObservationIgnored private var lastControlSessionFailure: ProMistControlError?
    @ObservationIgnored private let logger = Logger(
        subsystem: "com.demo.ProMist",
        category: "Bluetooth"
    )

    override init() {
        super.init()
        configureSessionCoordinators()
        configureProtocolTransport()
        trace("Initializing CoreBluetooth central")
        central = CBCentralManager(delegate: self, queue: nil)
    }

    private init(
        previewState: ProMistDeviceState,
        features: ProMistFeatureSet
    ) {
        let information = ProMistDeviceInformation(
            protocolVersion: ProMistBLEProtocol.version,
            hardwareRevision: 1,
            features: features
        )
        let profile = ProMistCapabilityResolver.resolve(
            deviceInformation: information,
            characteristics: ProMistCapabilityResolver.currentGATTCharacteristics
        )
        deviceState = previewState
        connectionState = .ready
        deviceInformation = information
        gattProfile = profile
        capabilities = profile.capabilities
        supportsRequiredSessionCharacteristics = true
        isAuthenticated = true
        super.init()
        configureSessionCoordinators()
        configureProtocolTransport()
    }

    private func configureSessionCoordinators() {
        knownDeviceCoordinator = ProMistKnownDeviceSessionCoordinator(
            dependencies: .init(
                executeAction: { [weak self] action in
                    self?.executeKnownDeviceTransportAction(action)
                },
                startRefreshConnection: { [weak self] target in
                    self?.startKnownFanConnection(
                        deviceID: target.deviceID,
                        name: target.name
                    )
                },
                connectionState: { [weak self] in
                    self?.connectionState ?? .idle
                },
                finishRefreshAttempt: { [weak self] generation in
                    await self?.finishKnownFanRefreshAttempt(
                        generation: generation
                    )
                },
                refreshStateChanged: { [weak self] isRefreshing in
                    self?.isRefreshingKnownFans = isRefreshing
                },
                trace: { [weak self] message in self?.trace(message) }
            )
        )
        authenticationEngine.eventHandler = { [weak self] action in
            self?.handleAuthenticationActions([action])
        }
        operationTracker.eventHandler = { [weak self] event in
            self?.handleOperationEvent(event)
        }
        localDeviceLifecycle.stateChanged = { [weak self] state in
            self?.recoveryRequiredDeviceID = state.recoveryRequiredDeviceID
            self?.ownershipResetCompletedDeviceID =
                state.ownershipResetCompletedDeviceID
            self?.sessionSnapshots = state.sessionSnapshots
        }
        matterCoordinator = ProMistMatterCommissioningCoordinator(
            dependencies: .init(
                requestOnboardingPayload: { [weak self] in
                    self?.write(
                        ProMistBLEProtocol.matterOnboardingRequest(),
                        to: ProMistBLEProtocol.matterOnboarding
                    ) ?? false
                },
                disconnectProprietarySession: { [weak self] in
                    self?.disconnect()
                },
                isTransportDisconnected: { [weak self] in
                    self?.peripheral == nil ||
                        self?.peripheral?.state == .disconnected
                },
                handoffStateChanged: { [weak self] active in
                    self?.isMatterCommissioningHandoff = active
                },
                trace: { [weak self] message in self?.trace(message) }
            )
        )
        applianceOperations = ProMistApplianceOperationCoordinator(
            dependencies: .init(
                session: { [weak self] in
                    ProMistApplianceOperationCoordinator.Session(
                        isAuthenticated: self?.isAuthenticated ?? false,
                        capabilities: self?.capabilities ?? .none,
                        supportsCustomBreezeSlots:
                            self?.supportsCustomBreezeSlots ?? false
                    )
                },
                submitCommand: { [weak self] opcode, value in
                    self?.commandEngine?.submit(opcode, value: value)
                },
                executeCommand: { [weak self] opcode, value in
                    guard let engine = self?.commandEngine else {
                        throw ProMistBLETransactionError.transportUnavailable
                    }
                    return try await engine.execute(opcode, value: value)
                },
                write: { [weak self] data, endpoint in
                    guard let self else { return false }
                    switch endpoint {
                    case .friendlyName:
                        return self.write(
                            data,
                            to: ProMistBLEProtocol.friendlyName
                        )
                    case .breezeSlot(let slot):
                        guard ProMistBLEProtocol.breezeSlots.indices.contains(slot)
                        else { return false }
                        return self.write(
                            data,
                            to: ProMistBLEProtocol.breezeSlots[slot]
                        )
                    }
                },
                beginFriendlyNameOperation: { [weak self] in
                    self?.operationTracker.begin(
                        .friendlyName,
                        label: "friendly name",
                        replacingExisting: true
                    )
                },
                trace: { [weak self] message in self?.trace(message) }
            )
        )
    }

    private func configureProtocolTransport() {
        let transport = CoreBluetoothBLETransport { [weak self] data, endpoint in
            guard let self else { return false }
            switch endpoint {
            case .command:
                return self.write(data, to: ProMistBLEProtocol.command)
            case .diagnosticRequest:
                return self.write(data, to: ProMistBLEProtocol.logRequest)
            case .commandResponse, .diagnosticData:
                return false
            }
        }
        let engine = ProMistBLECommandEngine(transport: transport)
        let diagnostics = ProMistDiagnosticsEngine(transport: transport)
        transport.eventHandler = { [weak engine, weak diagnostics] event in
            engine?.receive(event)
            diagnostics?.receive(event)
        }
        engine.transactionStarted = { [weak self] requestID in
            self?.beginCommandOperation(requestID: requestID)
        }
        engine.transactionFinished = { [weak self] requestID, _ in
            self?.finishCommandOperation(requestID: requestID)
        }
        diagnostics.recordsChanged = { [weak self] records in
            self?.diagnostics = records
        }
        diagnostics.finished = { [weak self] result in
            self?.completeDiagnosticRefresh(result)
        }
        protocolTransport = transport
        commandEngine = engine
        diagnosticEngine = diagnostics
    }

    func handleAuthenticationActions(
        _ actions: [ProMistBLEAuthenticationEngine.Action]
    ) {
        for action in actions {
            switch action {
            case .writeSecurity(let data):
                if !writeSecurity(data) {
                    handleAuthenticationActions(
                        authenticationEngine.transportRejected(action)
                    )
                }
            case .writeProvisioning(let data):
                if !writeProvisioning(data) {
                    handleAuthenticationActions(
                        authenticationEngine.transportRejected(action)
                    )
                }
            case .authenticationAccepted(let deviceID):
                completeAuthenticatedSession(deviceID: deviceID)
            case .ownershipResetCompleted(let deviceID):
                localDeviceLifecycle.completeOwnershipReset(for: deviceID)
            case .recoveryRequired(let deviceID):
                localDeviceLifecycle.requireRecovery(for: deviceID)
            case .timedOut(let deviceID, let phase):
                switch phase {
                case .authentication:
                    trace("Authentication timed out device=\(deviceID)")
                    guard sessionState.authenticationTimedOut(
                        deviceID: deviceID
                    ) else { continue }
                    failSecurity(
                        "The fan did not finish Bluetooth authentication. Put it in pairing mode and try again."
                    )
                case .capabilityResolution:
                    trace("Capability resolution timed out device=\(deviceID)")
                    failSecurity(
                        "The fan did not provide valid device capability information."
                    )
                }
            case .failed(let message):
                failSecurity(message)
            case .trace(let message):
                trace(message)
            }
        }
    }

    private func handleOperationEvent(
        _ event: ProMistDeviceOperationTracker.Event
    ) {
        switch event {
        case let .started(token, _, label, activeCount):
            activeDeviceOperationCount = activeCount
            trace(
                "Device I/O started id=\(token.rawValue) label=\(label) depth=\(activeCount)"
            )
        case let .finished(token, kind, reason, activeCount):
            if kind == .diagnostics { diagnosticRefreshRequested = false }
            activeDeviceOperationCount = activeCount
            trace(
                "Device I/O finished id=\(token.rawValue) reason=\(reason) depth=\(activeCount)"
            )
        case .cleared(let reason):
            diagnosticRefreshRequested = false
            activeDeviceOperationCount = 0
            trace("Device I/O cleared reason=\(reason)")
        }
    }

    static var preview: ProMistBLECentral {
        var state = ProMistDeviceState()
        state.power = true
        state.fanConfirmed = true
        state.fanSpeed = 3
        state.mistMode = 1
        state.oscillationMode = 2
        state.oscillationPosition = 2
        state.revision = 42
        state.deviceID = 1
        return ProMistBLECentral(
            previewState: state,
            features: .currentDevice
        )
    }

#if DEBUG
    static func uiTest(features: ProMistFeatureSet) -> ProMistBLECentral {
        var state = ProMistDeviceState()
        state.power = true
        state.fanConfirmed = true
        state.fanSpeed = 3
        state.mistMode = features.contains(.mist) ? 1 : 0
        state.oscillationMode = features.contains(.oscillation) ? 2 : 0
        state.oscillationPosition = features.contains(.oscillation) ? 1 : -128
        state.oscillationPositioning = features.contains(.positioning)
        state.oscillationTargetPosition = features.contains(.positioning) ? 2 : -128
        state.revision = 1
        state.deviceID = 1
        return ProMistBLECentral(previewState: state, features: features)
    }
#endif

    func sessionSnapshot(
        for deviceID: UInt64,
        at date: Date = .now
    ) -> ProMistSessionSnapshot? {
        localDeviceLifecycle.snapshot(for: deviceID, at: date)
    }

    func expireSessionSnapshots(at date: Date = .now) {
        localDeviceLifecycle.expireSnapshots(at: date)
    }

    func recordSessionSnapshot(_ state: ProMistDeviceState) {
        localDeviceLifecycle.recordSnapshot(
            state,
            authenticated: isAuthenticated
        )
    }

    func disconnectForMatterCommissioning(deviceID: UInt64) async throws {
        try await matterCoordinator.releaseTransportForCommissioning(
            deviceID: deviceID,
            authorized: connectionState == .ready &&
                deviceState.deviceID == deviceID && isAuthenticated
        )
    }

    func matterOnboardingPayload(deviceID: UInt64) async throws -> String {
        let characteristic =
            characteristics[ProMistBLEProtocol.matterOnboarding]
        return try await matterCoordinator.requestOnboardingPayload(
            available: connectionState == .ready &&
                deviceState.deviceID == deviceID && isAuthenticated &&
                capabilities.canProvideMatterOnboarding &&
                characteristic?.isNotifying == true
        )
    }

    func finishMatterCommissioningHandoff() {
        matterCoordinator.finishHandoff()
    }

    func resetAllLocalData(deviceIDs: [UInt64] = []) throws {
        try localDeviceLifecycle.resetAll(deviceIDs: deviceIDs)
        cancelKnownFanRefresh()
        trace("Local-data reset started")
        stopScanning()
        if let peripheral { central?.cancelPeripheralConnection(peripheral) }
        cancelStateRead()
        peripheral = nil
        selectedPeripheralIdentifier = nil
        requestedDeviceID = nil
        pendingKnownFanName = nil
        connectionAfterDisconnect = nil
        userRequestedDisconnect = false
        knownDeviceCoordinator.reset(
            bluetoothAvailable: central?.state == .poweredOn
        )
        clearDeviceOperations(reason: "local-data reset")
        nearbyPeripherals.removeAll()
        clearResolvedGATTProfile()
        discoveredFans.removeAll()
        diagnostics.removeAll()
        matterCoordinator.reset()
        deviceState = ProMistDeviceState()
        discoveredName = "ProMist"
        lastResponse = nil
        resetAuthentication()
        connectionState = central?.state == .poweredOn
            ? .idle
            : .bluetoothUnavailable
        trace("Local-data reset completed")
    }

    func forgetRecoveredDevice(deviceID: UInt64) throws {
        try forgetLocalDevice(deviceID: deviceID, peripheralIdentifier: nil)
    }

    func forgetLocalDevice(
        deviceID: UInt64,
        peripheralIdentifier: UUID?
    ) throws {
        let plan = try localDeviceLifecycle.forget(
            deviceID: deviceID,
            peripheralIdentifier: peripheralIdentifier,
            session: .init(
                requestedDeviceID: requestedDeviceID,
                connectedDeviceID: deviceState.deviceID,
                selectedPeripheralIdentifier: selectedPeripheralIdentifier,
                interactiveDeviceID:
                    knownDeviceCoordinator.interactiveTarget?.deviceID
            )
        )
        knownDeviceCoordinator.removeRefreshTarget(deviceID: deviceID)
        if plan.shouldEndInteractiveSession {
            knownDeviceCoordinator.endInteractiveSession(deviceID: deviceID)
        }
        if let peripheralIdentifier = plan.peripheralIdentifier {
            nearbyPeripherals.removeValue(forKey: peripheralIdentifier)
            discoveredFans.removeAll { $0.id == peripheralIdentifier }
        }
        guard plan.shouldResetActiveTransport else { return }

        cancelKnownFanRefresh()
        knownDeviceCoordinator.cancelReconnect()
        clearDeviceOperations(reason: "device forgotten locally")
        cancelStateRead()
        connectionAfterDisconnect = nil
        pendingKnownFanName = nil
        if let peripheral, peripheral.state != .disconnected {
            central.cancelPeripheralConnection(peripheral)
        }
        peripheral = nil
        selectedPeripheralIdentifier = nil
        requestedDeviceID = nil
        userRequestedDisconnect = false
        clearResolvedGATTProfile()
        diagnostics.removeAll()
        deviceState = ProMistDeviceState()
        discoveredName = "ProMist"
        resetAuthentication()
        connectionState = central.state == .poweredOn
            ? .idle
            : .bluetoothUnavailable
    }

    @discardableResult
    func resetOwnership(deviceID: UInt64) -> Bool {
        guard connectionState == .ready, isAuthenticated,
              deviceState.deviceID == deviceID else { return false }
        localDeviceLifecycle.beginOwnershipReset()
        guard let request = authenticationEngine.beginOwnershipReset(
            deviceID: deviceID
        ), writeSecurity(request) else {
            authenticationEngine.cancelOwnershipReset()
            return false
        }
        return true
    }

    func setPower(_ enabled: Bool) { applianceOperations.setPower(enabled) }
    func togglePower() { applianceOperations.togglePower() }
    func setFanSpeed(_ speed: UInt8) { applianceOperations.setFanSpeed(speed) }
    func setMist(_ enabled: Bool) { applianceOperations.setMist(enabled) }
    func setBreeze(_ mode: UInt8) { applianceOperations.setBreeze(mode) }
    func installAndSelectBreeze(_ preset: BreezePreset, slot: Int) {
        applianceOperations.installAndSelectBreeze(preset, slot: slot)
    }
    func clearBreezeSlot(_ slot: Int) {
        applianceOperations.clearBreezeSlot(slot)
    }
    func setOscillation(_ mode: UInt8) { applianceOperations.setOscillation(mode) }
    func jog(_ direction: Int8) { applianceOperations.jog(direction) }
    func home() { applianceOperations.home() }
    func setOscillationPosition(_ position: Int8) {
        applianceOperations.setOscillationPosition(position)
    }
    func setTimer(minutes: UInt8?) { applianceOperations.setTimer(minutes: minutes) }

    func clearFaults() async throws {
        guard try await applianceOperations.clearFaults(
            currentFault: deviceState.fault
        ) else { return }
        // A correlated success is authoritative even if the following state
        // notification is delayed or lost. Reconcile the visible safety state
        // immediately; the complete firmware snapshot will still follow.
        deviceState.power = false
        deviceState.fault = 0
        deviceState.timerRemainingSeconds = 0
        deviceState.timerDurationSeconds = 0
    }

    @discardableResult
    func setFriendlyName(_ name: String) -> Bool {
        applianceOperations.setFriendlyName(name)
    }

    func refreshDiagnostics() {
        diagnostics.removeAll()
        diagnosticRefreshRequested = true
        if knownDeviceCoordinator.interactiveTarget != nil {
            operationTracker.begin(
                .diagnostics,
                label: "diagnostics refresh",
                replacingExisting: true
            )
        }
        guard connectionState == .ready,
              isAuthenticated,
              capabilities.canReadDiagnostics,
              let peripheral,
              let metadata = characteristics[ProMistBLEProtocol.logMetadata]
        else {
            finishDiagnosticRefresh(reason: "diagnostics unavailable")
            trace("Diagnostics refresh rejected: metadata unavailable")
            return
        }
        trace("Diagnostics refresh requested")
        peripheral.readValue(for: metadata)
    }

    func finishDiagnosticRefresh(reason: String) {
        diagnosticRefreshRequested = false
        if diagnosticEngine?.isActive == true {
            diagnosticEngine?.cancel()
            trace("Diagnostic refresh finished: \(reason)")
            return
        }
        operationTracker.finish(.diagnostics, reason: reason)
    }

    private func completeDiagnosticRefresh(
        _ result: ProMistDiagnosticsEngine.Completion
    ) {
        diagnosticRefreshRequested = false
        let reason: String
        switch result {
        case .success:
            reason = "diagnostics received"
        case .failure(let error):
            reason = "diagnostics failed: \(error.localizedDescription)"
        }
        guard operationTracker.finish(.diagnostics, reason: reason) else {
            trace(reason)
            return
        }
    }

    @discardableResult
    private func write(_ data: Data, to uuid: CBUUID) -> Bool {
        guard connectionState == .ready else {
            trace("Write ignored: session is not ready uuid=\(shortUUID(uuid))")
            return false
        }
        guard let peripheral, let characteristic = characteristics[uuid] else {
            trace("Write ignored: characteristic missing uuid=\(shortUUID(uuid))")
            return false
        }
        trace("Writing \(data.count) bytes uuid=\(shortUUID(uuid))")
        peripheral.writeValue(data, for: characteristic, type: .withResponse)
        return true
    }

    private func writeSecurity(_ data: Data) -> Bool {
        guard connectionState == .discovering || connectionState == .ready,
              let peripheral,
              let characteristic = characteristics[ProMistBLEProtocol.security]
        else { return false }
        peripheral.writeValue(data, for: characteristic, type: .withResponse)
        return true
    }

    private func writeProvisioning(_ data: Data) -> Bool {
        guard connectionState == .discovering || connectionState == .ready,
              let peripheral,
              let characteristic = characteristics[ProMistBLEProtocol.provisioning]
        else { return false }
        peripheral.writeValue(data, for: characteristic, type: .withResponse)
        return true
    }

    func clearResolvedGATTProfile() {
        cancelInformationRead()
        characteristics.removeAll()
        gattProfile = .unresolved
        deviceInformation = nil
        capabilities = .none
        supportsRequiredSessionCharacteristics = false
        fanBreezeSlots = [nil, nil, nil]
        applianceOperations.cancelBreezeTransfer()
    }

    private func beginAuthentication(deviceID: UInt64) {
        handleAuthenticationActions(authenticationEngine.begin(deviceID: deviceID))
    }

    func beginAuthenticationWhenSecurityIsReady(deviceID: UInt64) {
        guard !sessionReachedReady, !isAuthenticated,
              authenticationEngine.deviceID == nil else { return }
        let securityNotificationsReady =
            characteristics[ProMistBLEProtocol.security]?.isNotifying == true
        guard securityNotificationsReady else {
            _ = sessionState.receiveIdentity(
                deviceID,
                securityNotificationsReady: false
            )
            return
        }
        if requestedDeviceID != nil, let peripheral {
            switch knownDeviceCoordinator.receiveFirmwareIdentity(
                deviceID,
                peripheralIdentifier: peripheral.identifier
            ) {
            case .authenticate:
                break
            case .rejectMismatch:
                failSecurity(
                    "Device identity mismatch. The discovered fan is not the saved device."
                )
                return
            case .ignoreStale:
                trace("Ignoring identity from a stale connection attempt")
                return
            }
        }
        switch sessionState.receiveIdentity(
            deviceID,
            securityNotificationsReady: securityNotificationsReady
        ) {
        case .ignoreStale:
            trace("Ignoring identity from a stale connection phase")
            return
        case .waitForSecurity:
            return
        case let .authenticate(verifiedDeviceID):
            cancelStateRead()
            beginAuthentication(deviceID: verifiedDeviceID)
        case .rejectMismatch:
            trace(
                "Identity mismatch expected=\(String(describing: requestedDeviceID)) received=\(deviceID)"
            )
            failSecurity("Device identity mismatch. The discovered fan is not the saved device.")
        }
    }

    func resetAuthentication() {
        authenticationEngine.reset()
        isAuthenticated = false
    }

    func failSecurity(_ message: String) {
        if let authenticationDeviceID = authenticationEngine.deviceID {
            _ = sessionState.authenticationFailed(deviceID: authenticationDeviceID)
        } else {
            sessionState.fail()
        }
        cancelInformationRead()
        resetAuthentication()
        lastControlSessionFailure = .authenticationUnavailable
        connectionState = .failed(message)
        if let peripheral { central.cancelPeripheralConnection(peripheral) }
    }

    private func completeAuthenticatedSession(deviceID: UInt64) {
        guard supportsRequiredSessionCharacteristics else {
            failSecurity("The ProMist BLE service is incomplete")
            return
        }
        guard deviceID == deviceState.deviceID,
              sessionState.authenticationSucceeded(deviceID: deviceID) else {
            failSecurity("The fan returned an authentication response outside an active session.")
            return
        }
        isAuthenticated = true
        finishReadySessionIfCapabilitiesResolved()
    }

    func finishReadySessionIfCapabilitiesResolved() {
        guard isAuthenticated, let deviceInformation,
              gattProfile.supportsRequiredSession else { return }
        guard sessionState.capabilityResolutionSucceeded(
            deviceID: deviceState.deviceID
        ) else {
            failSecurity("The fan completed capability discovery outside an active session.")
            return
        }
        if requestedDeviceID != nil,
           !knownDeviceCoordinator.authenticationCompleted(
               deviceID: deviceState.deviceID
           ) {
            failSecurity(
                "The fan completed authentication for a superseded connection attempt."
            )
            return
        }
        authenticationEngine.capabilitiesResolved()
        capabilities = gattProfile.capabilities
        cancelStateRead()
        knownDeviceCoordinator.cancelReconnect()
        sessionReachedReady = true
        lastControlSessionFailure = nil
        connectionState = .ready
        recordSessionSnapshot(deviceState)
        trace(
            "Device identity verified; owner authenticated; capabilities resolved hardware=\(deviceInformation.hardwareRevision) features=0x\(String(deviceInformation.features.rawValue, radix: 16))"
        )
    }

    private func beginCommandOperation(requestID: UInt32) {
        guard knownDeviceCoordinator.interactiveTarget != nil else { return }
        operationTracker.begin(
            .command(requestID: requestID),
            label: "command \(requestID)"
        )
    }

    func beginStateRefreshOperationIfInteractive() {
        guard knownDeviceCoordinator.interactiveTarget != nil else { return }
        operationTracker.begin(
            .stateRefresh,
            label: "state refresh",
            replacingExisting: true
        )
    }

    private func finishCommandOperation(requestID: UInt32) {
        operationTracker.finish(
            .command(requestID: requestID),
            reason: "command response"
        )
    }

    func finishStateRefreshOperation() {
        operationTracker.finish(
            .stateRefresh,
            reason: "state received"
        )
    }

    func clearDeviceOperations(reason: String) {
        commandEngine?.cancelAll()
        diagnosticRefreshRequested = false
        diagnosticEngine?.cancel()
        operationTracker.clear(reason: reason)
        matterCoordinator.cancelOnboardingRequest()
    }

    func discover(_ peripheral: CBPeripheral) {
        cancelConnectionTimeout()
        connectionState = .discovering
        trace("Connected; discovering ProMist service")
        peripheral.delegate = self
        peripheral.discoverServices([ProMistBLEProtocol.service])
    }

    func requestDeviceState(afterNanoseconds delay: UInt64 = 0) {
        guard !sessionReachedReady, let peripheral,
            let stateCharacteristic = characteristics[ProMistBLEProtocol.state]
        else { return }
        knownDeviceCoordinator.requestRead(
            .state,
            afterNanoseconds: delay,
            shouldRun: { [weak self, weak peripheral] in
                guard let self, let peripheral else { return false }
                return !self.sessionReachedReady &&
                    peripheral.identifier == self.selectedPeripheralIdentifier &&
                    self.connectionState == .discovering
            },
            perform: { [weak self, weak peripheral] attempt in
                guard let self, let peripheral else { return }
                self.trace("Requesting device state attempt=\(attempt)")
                peripheral.readValue(for: stateCharacteristic)
            },
            exhausted: { [weak self] in
                self?.connectionState = .failed(
                    "The fan connected, but its state could not be loaded. Try reconnecting."
                )
                self?.trace("Device state timed out after 3 attempts")
            }
        )
    }

    func cancelStateRead() {
        knownDeviceCoordinator.cancelRead(.state)
    }

    func requestDeviceInformation(
        afterNanoseconds delay: UInt64 = 0
    ) {
        guard !sessionReachedReady, deviceInformation == nil, let peripheral,
            let characteristic = characteristics[ProMistBLEProtocol.information]
        else { return }
        knownDeviceCoordinator.requestRead(
            .information,
            afterNanoseconds: delay,
            shouldRun: { [weak self, weak peripheral] in
                guard let self, let peripheral else { return false }
                return !self.sessionReachedReady &&
                    self.deviceInformation == nil &&
                    peripheral.identifier == self.selectedPeripheralIdentifier &&
                    self.connectionState == .discovering
            },
            perform: { [weak self, weak peripheral] attempt in
                guard let self, let peripheral else { return }
                self.trace("Requesting device information attempt=\(attempt)")
                peripheral.readValue(for: characteristic)
            },
            exhausted: { [weak self] in
                self?.trace("Device information timed out after 3 attempts")
                self?.failSecurity(
                    "The fan connected, but its capability information could not be loaded. Try reconnecting."
                )
            }
        )
    }

    func cancelInformationRead() {
        knownDeviceCoordinator.cancelRead(.information)
    }

    func armConnectionTimeout(for selected: CBPeripheral) {
        cancelConnectionTimeout()
        let identifier = selected.identifier
        connectionTimeoutTask = Task { @MainActor [weak self, weak selected] in
            try? await Task.sleep(for: .seconds(10))
            guard
                !Task.isCancelled,
                let self,
                let selected,
                self.selectedPeripheralIdentifier == identifier,
                self.connectionState == .connecting,
                self.sessionState.connectionTimedOut()
            else { return }

            self.connectionTimeoutTask = nil
            self.trace("Connection timed out id=\(identifier.uuidString)")
            self.clearDeviceOperations(reason: "connection timed out")
            self.central.cancelPeripheralConnection(selected)
            if self.relaunchPendingConnection(afterCancelling: selected) {
                return
            }
            self.peripheral = nil
            self.selectedPeripheralIdentifier = nil

            let reconnectAction = self.knownDeviceCoordinator.receiveAttemptTimeout(
                "Connection timed out"
            )
            if case .scheduleReconnect = reconnectAction {
                self.sessionReachedReady = false
                self.connectionState = .connecting
                self.knownDeviceCoordinator.execute(reconnectAction)
                return
            }
            self.connectionState = .failed(
                "The Bluetooth connection timed out. Try again."
            )
        }
    }

    func cancelConnectionTimeout() {
        connectionTimeoutTask?.cancel()
        connectionTimeoutTask = nil
    }

    private func shortUUID(_ uuid: CBUUID) -> String {
        String(uuid.uuidString.prefix(8))
    }

    func errorDescription(_ error: Error?) -> String {
        guard let error else { return "none" }
        let value = error as NSError
        return "domain=\(value.domain) code=\(value.code) message=\(value.localizedDescription)"
    }

    func connectionFailureMessage(_ error: Error?) -> String {
        guard let error else { return "Connection failed" }
        let value = error as NSError
        if value.domain == CBErrorDomain,
           value.code == CBError.Code.peerRemovedPairingInformation.rawValue {
            return "The fan’s Bluetooth pairing was reset. If ProMist appears in Settings › Bluetooth, forget it there, put the fan into provisioning mode, and try Add Fan again."
        }
        return value.localizedDescription
    }

    func trace(_ message: String) {
        logger.debug("\(message, privacy: .public)")
#if DEBUG
        print("[ProMist BLE] \(message)")
#endif
    }
}

extension ProMistBLECentral: ProMistControlSessionBackend {
    func controlSessionStatus(for deviceID: UInt64) -> ProMistDeviceSessionStatus {
        if connectionState == .bluetoothUnavailable { return .bluetoothUnavailable }
        let matchesRequest = requestedDeviceID == deviceID
        let matchesIdentity = deviceState.deviceID == deviceID
        let matchesAuthentication = authenticationEngine.deviceID == deviceID
        guard matchesRequest || matchesIdentity || matchesAuthentication else {
            return .idle
        }
        switch connectionState {
        case .bluetoothUnavailable:
            return .bluetoothUnavailable
        case .idle:
            return .idle
        case .scanning:
            return .resolving
        case .connecting:
            return .connecting
        case .discovering:
            return matchesAuthentication ? .authenticating : .discovering
        case .ready:
            return matchesIdentity && isAuthenticated ? .ready : .authenticating
        case .failed:
            return .failed(lastControlSessionFailure ?? .deviceNotFound)
        }
    }

    func hasOwnerCredential(for deviceID: UInt64) -> Bool {
        authenticationEngine.hasCredential(for: deviceID)
    }

    func beginControlSession(deviceID: UInt64, name: String) {
        lastControlSessionFailure = nil
        beginDeviceSession(deviceID: deviceID, name: name)
        publishControlSessionStatus()
    }

    func executeControlCommand(
        _ command: ProMistControlCommand,
        deviceID: UInt64
    ) async throws {
        guard connectionState == .ready,
              deviceState.deviceID == deviceID,
              isAuthenticated else {
            throw ProMistControlError.authenticationUnavailable
        }

        try await applianceOperations.executeControlCommand(command)
    }

    private func publishControlSessionStatus() {
        guard let controlSessionEventHandler else { return }
        var deviceIDs = Set<UInt64>()
        if let requestedDeviceID { deviceIDs.insert(requestedDeviceID) }
        if let authenticationDeviceID = authenticationEngine.deviceID {
            deviceIDs.insert(authenticationDeviceID)
        }
        if deviceState.deviceID != 0 { deviceIDs.insert(deviceState.deviceID) }
        for deviceID in deviceIDs {
            controlSessionEventHandler(deviceID, controlSessionStatus(for: deviceID))
        }
    }
}
