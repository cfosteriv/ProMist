// CBCentralManager callback adapter.
import Foundation
@preconcurrency import CoreBluetooth

extension ProMistBLECentral: @preconcurrency CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        trace("Bluetooth state changed raw=\(central.state.rawValue)")
        knownDeviceCoordinator.bluetoothAvailabilityChanged(
            isAvailable: central.state == .poweredOn
        )
        if central.state != .poweredOn {
            cancelConnectionTimeout()
        }
        connectionState = central.state == .poweredOn
            ? .idle
            : .bluetoothUnavailable
        if central.state == .poweredOn {
            beginQueuedKnownFanRefreshIfPossible()
        }
    }

    func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        let name =
            (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ??
            peripheral.name ??
            "ProMist"
        nearbyPeripherals[peripheral.identifier] = peripheral
        let fan = DiscoveredFan(
            id: peripheral.identifier,
            name: name,
            rssi: RSSI.intValue
        )
        let previousRSSI = discoveredFans.first(where: { $0.id == fan.id })?.rssi
        if let index = discoveredFans.firstIndex(where: { $0.id == fan.id }) {
            discoveredFans[index] = fan
        } else {
            discoveredFans.append(fan)
        }
        discoveredFans.sort { $0.rssi > $1.rssi }
        if previousRSSI == nil || abs((previousRSSI ?? 0) - RSSI.intValue) >= 10 {
            trace(
                "Discovered name=\(name) id=\(peripheral.identifier.uuidString) rssi=\(RSSI.intValue)"
            )
        }
        if pendingKnownFanName != nil, requestedDeviceID != nil {
            let action = knownDeviceCoordinator.receiveAdvertisement(
                peripheralIdentifier: peripheral.identifier,
                observedName: name
            )
            guard action != .ignore else { return }
            trace(
                "Known fan rediscovered advertised=\(name) expected=\(pendingKnownFanName ?? "unknown")"
            )
            self.pendingKnownFanName = nil
            knownDeviceCoordinator.execute(action)
        }
    }

    func centralManager(
        _ central: CBCentralManager,
        didConnect peripheral: CBPeripheral
    ) {
        if requestedDeviceID != nil {
            let action = knownDeviceCoordinator.receiveConnected(
                peripheralIdentifier: peripheral.identifier
            )
            guard case .discoverServices = action else {
                trace("Rejecting stale or cancelled known-device connection")
                knownDeviceCoordinator.execute(action)
                return
            }
            cancelConnectionTimeout()
            connectionAfterDisconnect = nil
            userRequestedDisconnect = false
            commandEngine?.resetRequestSequence()
            protocolTransport?.receive(.reconnected)
            resetAuthentication()
            sessionState.beginConnection(expectedDeviceID: requestedDeviceID)
            trace("Validated known-device link id=\(peripheral.identifier.uuidString)")
            knownDeviceCoordinator.execute(action)
            return
        }
        guard peripheral.identifier == selectedPeripheralIdentifier else {
            trace("Ignoring connection from superseded peripheral")
            central.cancelPeripheralConnection(peripheral)
            return
        }
        guard !userRequestedDisconnect else {
            trace("Ignoring connection callback after explicit cancellation")
            central.cancelPeripheralConnection(peripheral)
            return
        }
        cancelConnectionTimeout()
        connectionAfterDisconnect = nil
        userRequestedDisconnect = false
        commandEngine?.resetRequestSequence()
        protocolTransport?.receive(.reconnected)
        resetAuthentication()
        sessionState.beginConnection(expectedDeviceID: requestedDeviceID)
        trace("Link connected id=\(peripheral.identifier.uuidString)")
        discover(peripheral)
    }

    func centralManager(
        _ central: CBCentralManager,
        didFailToConnect peripheral: CBPeripheral,
        error: Error?
    ) {
        guard peripheral.identifier == selectedPeripheralIdentifier else {
            trace("Ignoring failure from superseded peripheral")
            return
        }
        let policyAction = requestedDeviceID == nil
            ? ProMistBLEConnectionPolicy.Action.ignore
            : knownDeviceCoordinator.receiveDisconnected(
                peripheralIdentifier: peripheral.identifier
            )
        if userRequestedDisconnect {
            userRequestedDisconnect = false
            self.peripheral = nil
            selectedPeripheralIdentifier = nil
            connectionState = central.state == .poweredOn ? .idle : .bluetoothUnavailable
            trace("Ignoring connection failure after explicit cancellation")
            return
        }
        cancelConnectionTimeout()
        if relaunchPendingConnection(afterCancelling: peripheral) {
            return
        }
        if case .startScan = policyAction {
            sessionReachedReady = false
            knownDeviceCoordinator.execute(policyAction)
            return
        }
        userRequestedDisconnect = false
        knownDeviceCoordinator.cancelReconnect()
        clearDeviceOperations(reason: "connection failed")
        trace("Link failed: \(errorDescription(error))")
        connectionState = .failed(connectionFailureMessage(error))
    }

    func centralManager(
        _ central: CBCentralManager,
        didDisconnectPeripheral peripheral: CBPeripheral,
        error: Error?
    ) {
        guard peripheral.identifier == selectedPeripheralIdentifier else {
            trace("Ignoring disconnect from superseded peripheral")
            return
        }
        cancelConnectionTimeout()
        trace(
            "Link disconnected ready=\(sessionReachedReady) \(errorDescription(error))"
        )
        let policyAction = requestedDeviceID == nil
            ? ProMistBLEConnectionPolicy.Action.ignore
            : knownDeviceCoordinator.receiveDisconnected(
                peripheralIdentifier: peripheral.identifier
            )
        protocolTransport?.receive(.disconnected)
        let reconnectRequested: Bool
        if case .scheduleReconnect = policyAction {
            reconnectRequested = true
        } else {
            reconnectRequested = false
        }
        _ = sessionState.disconnect(reconnectRequested: reconnectRequested)
        cancelStateRead()
        resetAuthentication()
        clearResolvedGATTProfile()
        if relaunchPendingConnection(afterCancelling: peripheral) {
            return
        }
        if case .startScan = policyAction {
            sessionReachedReady = false
            knownDeviceCoordinator.execute(policyAction)
            return
        }
        if userRequestedDisconnect {
            userRequestedDisconnect = false
            sessionReachedReady = false
            connectionState = .idle
            trace("User disconnect completed")
            return
        }
        if case .scheduleReconnect = policyAction {
            clearDeviceOperations(reason: "link interrupted")
            sessionReachedReady = false
            connectionState = .connecting
            knownDeviceCoordinator.execute(policyAction)
            return
        }
        clearDeviceOperations(reason: "link disconnected")
        if !sessionReachedReady {
            connectionState = .failed(
                error?.localizedDescription ??
                "The fan disconnected before its controls were loaded."
            )
        } else {
            connectionState = .failed(
                error?.localizedDescription ??
                "The Bluetooth connection to \(discoveredName) was lost."
            )
        }
        sessionReachedReady = false
    }
}
