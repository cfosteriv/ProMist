// CoreBluetooth discovery and connection entry points. Transport delegate
// callbacks remain in their dedicated extensions.
import Foundation
@preconcurrency import CoreBluetooth

extension ProMistBLECentral {
    func scan() {
        cancelKnownFanRefresh()
        knownDeviceCoordinator.reset(
            bluetoothAvailable: central.state == .poweredOn
        )
        pendingKnownFanName = nil
        requestedDeviceID = nil
        startScan()
    }

    private func startScan(knownTarget: KnownFanTarget? = nil) {
        cancelConnectionTimeout()
        guard central.state == .poweredOn else {
            trace("Scan rejected: Bluetooth state=\(central.state.rawValue)")
            connectionState = .bluetoothUnavailable
            return
        }
        if let peripheral {
            central.cancelPeripheralConnection(peripheral)
        }
        cancelStateRead()
        connectionAfterDisconnect = nil
        userRequestedDisconnect = false
        pendingKnownFanName = knownTarget?.name
        requestedDeviceID = knownTarget?.deviceID
        peripheral = nil
        selectedPeripheralIdentifier = nil
        sessionReachedReady = false
        resetAuthentication()
        clearResolvedGATTProfile()
        discoveredFans.removeAll()
        nearbyPeripherals.removeAll()
        connectionState = .scanning
        trace("Scan started for ProMist service")
        central.scanForPeripherals(
            withServices: [ProMistBLEProtocol.service],
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: true]
        )
    }

    func stopScanning() {
        central?.stopScan()
        trace("Scan stopped; results=\(discoveredFans.count)")
        if connectionState == .scanning { connectionState = .idle }
    }

    func connect(to fan: DiscoveredFan) {
        cancelKnownFanRefresh()
        guard let selected = nearbyPeripherals[fan.id] else {
            trace("Connect rejected: stale result id=\(fan.id.uuidString)")
            connectionState = .failed(
                "That fan is no longer available. Search again."
            )
            return
        }
        pendingKnownFanName = nil
        requestedDeviceID = nil
        beginConnection(to: selected, name: fan.name)
    }

    func connect(toKnownDeviceID deviceID: UInt64, name: String) {
        cancelKnownFanRefresh()
        startKnownFanConnection(deviceID: deviceID, name: name)
    }

    func beginDeviceSession(deviceID: UInt64, name: String) {
        trace(
            "Interactive session requested name=\(name) device=\(deviceID)"
        )
        let target = KnownFanTarget(deviceID: deviceID, name: name)

        if adoptReadyDeviceSessionIfPossible(target) { return }
        let action = knownDeviceCoordinator.beginInteractiveSession(for: target)
        guard action != .ignore else {
            switch connectionState {
            case .idle, .failed:
                trace(
                    "Terminal transport state superseded stale policy attempt name=\(name) device=\(deviceID)"
                )
                knownDeviceCoordinator.cancelReconnect()
                knownDeviceCoordinator.execute(
                    knownDeviceCoordinator.beginKnownDeviceResolution(for: target)
                )
                return
            case .bluetoothUnavailable, .scanning, .connecting, .discovering,
                 .ready:
                trace("Interactive session retained active policy attempt")
                return
            }
        }
        knownDeviceCoordinator.cancelReconnect()
        knownDeviceCoordinator.execute(action)
    }

    /// Re-establishes a visible device session after lifecycle changes without
    /// disturbing a scan, connection, or discovery that CoreBluetooth is still
    /// actively performing for the same fan.
    func resumeDeviceSession(deviceID: UInt64, name: String) {
        let target = KnownFanTarget(deviceID: deviceID, name: name)
        if adoptReadyDeviceSessionIfPossible(target) { return }
        if knownDeviceCoordinator.hasActiveAttempt(for: target) {
            trace(
                "Lifecycle resume retained active connection name=\(name) device=\(deviceID)"
            )
            return
        }

        knownDeviceCoordinator.cancelReconnect()
        trace(
            "Lifecycle resume launching connection name=\(name) device=\(deviceID)"
        )
        knownDeviceCoordinator.execute(
            knownDeviceCoordinator.beginInteractiveSession(for: target)
        )
    }

    /// A physical retry is intentionally disruptive: cancel every coordinator
    /// task for the current attempt, wait for CoreBluetooth to finish cancelling
    /// its link, then relaunch through the normal known-device connection path.
    func restartDeviceSessionFromUserTap(deviceID: UInt64, name: String) {
        let target = KnownFanTarget(deviceID: deviceID, name: name)
        trace(
            "Physical retry requested name=\(name) device=\(deviceID)"
        )

        cancelKnownFanRefresh()
        _ = knownDeviceCoordinator.beginInteractiveSession(for: target)
        knownDeviceCoordinator.cancelReconnect()
        central.stopScan()
        pendingKnownFanName = nil
        cancelConnectionTimeout()
        cancelStateRead()
        cancelInformationRead()
        clearDeviceOperations(reason: "physical connection retry")
        resetAuthentication()
        clearResolvedGATTProfile()
        sessionState.reset()
        sessionReachedReady = false
        requestedDeviceID = deviceID
        connectionState = .connecting

        if let current = peripheral, current.state != .disconnected {
            connectionAfterDisconnect = nil
            userRequestedDisconnect = false
            sessionState.beginConnection(expectedDeviceID: deviceID)
            trace(
                "Physical retry cancelling active link id=\(current.identifier.uuidString)"
            )
            knownDeviceCoordinator.execute(
                knownDeviceCoordinator.supersedeAfterDisconnect(
                    with: target,
                    peripheralIdentifier: current.identifier
                )
            )
            armConnectionTimeout(for: current)
            return
        }

        connectionAfterDisconnect = nil
        userRequestedDisconnect = false
        peripheral = nil
        selectedPeripheralIdentifier = nil
        knownDeviceCoordinator.execute(
            knownDeviceCoordinator.beginKnownDeviceResolution(for: target)
        )
    }

    func endDeviceSession(deviceID: UInt64) {
        guard knownDeviceCoordinator.interactiveTarget?.deviceID == deviceID else {
            return
        }
        knownDeviceCoordinator.endInteractiveSession(deviceID: deviceID)
        clearDeviceOperations(reason: "device screen closed")
    }

    func startKnownFanConnection(deviceID: UInt64, name: String) {
        if connectionState == .ready, deviceState.deviceID == deviceID {
            trace("Known fan is already connected; refreshing state device=\(deviceID)")
            if
                let peripheral,
                let stateCharacteristic = characteristics[ProMistBLEProtocol.state]
            {
                beginStateRefreshOperationIfInteractive()
                peripheral.readValue(for: stateCharacteristic)
            }
            return
        }

        let target = KnownFanTarget(deviceID: deviceID, name: name)
        if knownDeviceCoordinator.hasActiveAttempt(for: target) {
            trace(
                "Known fan connection already active name=\(name) device=\(deviceID)"
            )
            return
        }
        knownDeviceCoordinator.execute(
            knownDeviceCoordinator.beginKnownDeviceResolution(for: target)
        )
    }

    /// Executes explicit decisions from the CoreBluetooth-independent policy.
    /// The policy never owns a manager, peripheral, delegate, or timer.
    func executeKnownDeviceTransportAction(
        _ action: ProMistBLEConnectionPolicy.Action
    ) {
        switch action {
        case let .startScan(target, _):
            trace("Scanning for known fan name=\(target.name)")
            startScan(knownTarget: target)
        case .stopScan:
            central.stopScan()
        case let .connect(identifier, _):
            guard let selected = nearbyPeripherals[identifier] else {
                knownDeviceCoordinator.failCurrentAttempt("Peripheral disappeared")
                connectionState = .failed(
                    "That fan is no longer available. Search again."
                )
                return
            }
            pendingKnownFanName = nil
            beginConnection(to: selected, name: selected.name ?? "ProMist")
        case let .cancelConnection(identifier):
            if let selected = nearbyPeripherals[identifier] ?? peripheral {
                central.cancelPeripheralConnection(selected)
            }
        case let .discoverServices(identifier, _):
            guard let selected = nearbyPeripherals[identifier] ?? peripheral,
                  selected.identifier == identifier else { return }
            discover(selected)
        case .scheduleReconnect:
            assertionFailure("Reconnect scheduling must remain coordinator-owned")
        case .ignore:
            break
        }
    }

    func refreshKnownFans(_ targets: [KnownFanTarget]) {
        guard !isMatterCommissioningHandoff else {
            trace("Known fan refresh skipped during Matter commissioning handoff")
            return
        }
        cancelKnownFanRefresh()
        guard !targets.isEmpty else {
            trace("Known fan refresh skipped: no stored fans")
            return
        }
        knownDeviceCoordinator.startRefresh(targets, allowed: true)
        beginQueuedKnownFanRefreshIfPossible()
    }

    func cancelKnownFanRefresh() {
        guard knownDeviceCoordinator.cancelRefresh() else { return }
        central?.stopScan()
        pendingKnownFanName = nil
        connectionAfterDisconnect = nil
        cancelConnectionTimeout()
        cancelStateRead()

        if let peripheral, peripheral.state != .disconnected {
            userRequestedDisconnect = true
            central?.cancelPeripheralConnection(peripheral)
        }
        connectionState = central?.state == .poweredOn
            ? .idle
            : .bluetoothUnavailable
        trace("Known fan refresh cancelled")
    }

    func beginQueuedKnownFanRefreshIfPossible() {
        knownDeviceCoordinator.beginRefreshIfPossible(
            bluetoothAvailable: central?.state == .poweredOn
        )
    }

    func finishKnownFanRefreshAttempt(generation: UInt64) async {
        central.stopScan()
        pendingKnownFanName = nil
        connectionAfterDisconnect = nil
        cancelConnectionTimeout()
        cancelStateRead()

        if let peripheral, peripheral.state != .disconnected {
            userRequestedDisconnect = true
            central.cancelPeripheralConnection(peripheral)
            for _ in 0..<12 {
                guard
                    !Task.isCancelled,
                    knownDeviceCoordinator.isCurrentRefresh(generation)
                else { return }
                if peripheral.state == .disconnected { break }
                try? await Task.sleep(for: .milliseconds(250))
            }
        }

        guard
            !Task.isCancelled,
            knownDeviceCoordinator.isCurrentRefresh(generation)
        else { return }
        peripheral = nil
        selectedPeripheralIdentifier = nil
        requestedDeviceID = nil
        sessionReachedReady = false
        userRequestedDisconnect = false
        clearResolvedGATTProfile()
        deviceState = ProMistDeviceState()
        connectionState = central.state == .poweredOn
            ? .idle
            : .bluetoothUnavailable
    }

    func connectionState(
        forDeviceID deviceID: UInt64,
        peripheralIdentifier: UUID?
    ) -> ProMistConnectionState {
        if connectionState == .bluetoothUnavailable {
            return .bluetoothUnavailable
        }
        let matchesPeripheral = peripheralIdentifier != nil &&
            peripheralIdentifier == selectedPeripheralIdentifier
        let matchesDevice = deviceState.deviceID != 0 &&
            deviceState.deviceID == deviceID
        let matchesRequest = requestedDeviceID == deviceID
        return matchesPeripheral || matchesDevice || matchesRequest
            ? connectionState
            : .idle
    }

    /// The Add Fan path authenticates before a saved-device target exists. Once
    /// its device screen becomes interactive, synchronize that already-ready
    /// physical session into the known-device policy so reconnect and later taps
    /// cannot be blocked by a phantom `.resolving` attempt.
    private func adoptReadyDeviceSessionIfPossible(
        _ target: KnownFanTarget
    ) -> Bool {
        guard connectionState == .ready,
              isAuthenticated,
              deviceState.deviceID == target.deviceID else { return false }

        if knownDeviceCoordinator.cancelRefresh() {
            central.stopScan()
            trace(
                "Interactive session took ownership of ready refresh connection name=\(target.name) device=\(target.deviceID)"
            )
        }
        requestedDeviceID = target.deviceID
        knownDeviceCoordinator.adoptReadyInteractiveSession(
            for: target,
            peripheralIdentifier: selectedPeripheralIdentifier
        )
        trace(
            "Adopted authenticated link into interactive policy name=\(target.name) device=\(target.deviceID)"
        )
        if let peripheral,
           let stateCharacteristic = characteristics[ProMistBLEProtocol.state] {
            beginStateRefreshOperationIfInteractive()
            peripheral.readValue(for: stateCharacteristic)
        }
        return true
    }

    private func beginConnection(to selected: CBPeripheral, name: String) {
        central.stopScan()
        cancelStateRead()
        if let current = peripheral, current.identifier != selected.identifier {
            central.cancelPeripheralConnection(current)
        }
        let waitingForPreviousCancellation =
            peripheral?.identifier == selected.identifier &&
            userRequestedDisconnect
        peripheral = selected
        selectedPeripheralIdentifier = selected.identifier
        discoveredName = name
        deviceState = ProMistDeviceState()
        diagnostics.removeAll()
        fanBreezeSlots = [nil, nil, nil]
        clearResolvedGATTProfile()
        sessionReachedReady = false
        sessionState.beginConnection(expectedDeviceID: requestedDeviceID)
        connectionState = .connecting

        if waitingForPreviousCancellation || selected.state == .disconnecting {
            connectionAfterDisconnect = (requestedDeviceID, name)
            userRequestedDisconnect = false
            trace(
                "Reconnect queued until disconnect completes id=\(selected.identifier.uuidString)"
            )
        } else if selected.state == .connected {
            connectionAfterDisconnect = nil
            userRequestedDisconnect = false
            trace("Reusing connected peripheral id=\(selected.identifier.uuidString)")
            discover(selected)
        } else if selected.state == .connecting {
            connectionAfterDisconnect = nil
            userRequestedDisconnect = false
            trace("Connection already pending id=\(selected.identifier.uuidString)")
        } else {
            connectionAfterDisconnect = nil
            userRequestedDisconnect = false
            trace("Connecting name=\(name) id=\(selected.identifier.uuidString)")
            central.connect(selected)
        }
        if connectionState == .connecting {
            armConnectionTimeout(for: selected)
        }
    }

    @discardableResult
    func relaunchPendingConnection(
        afterCancelling cancelledPeripheral: CBPeripheral
    ) -> Bool {
        guard let pending = connectionAfterDisconnect else { return false }
        connectionAfterDisconnect = nil
        userRequestedDisconnect = false
        peripheral = nil
        selectedPeripheralIdentifier = nil
        sessionReachedReady = false
        connectionState = .connecting

        if let deviceID = pending.deviceID {
            trace(
                "Cancellation complete; relaunching known-device path name=\(pending.name) device=\(deviceID)"
            )
            startKnownFanConnection(deviceID: deviceID, name: pending.name)
        } else {
            trace(
                "Cancellation complete; relaunching discovered-device path id=\(cancelledPeripheral.identifier.uuidString)"
            )
            requestedDeviceID = nil
            beginConnection(to: cancelledPeripheral, name: pending.name)
        }
        return true
    }

    func disconnect() {
        cancelKnownFanRefresh()
        trace("User requested disconnect")
        let policyAction = knownDeviceCoordinator.requestDisconnect(
            peripheralIdentifier: peripheral?.identifier
        )
        cancelConnectionTimeout()
        clearDeviceOperations(reason: "user disconnect")
        sessionState.reset()
        pendingKnownFanName = nil
        connectionAfterDisconnect = nil
        cancelStateRead()
        if let peripheral, peripheral.state != .disconnected {
            userRequestedDisconnect = true
            knownDeviceCoordinator.execute(policyAction)
        } else {
            userRequestedDisconnect = false
        }
        connectionState = .idle
    }
}
