// CBPeripheral GATT callback adapter.
import Foundation
@preconcurrency import CoreBluetooth

extension ProMistBLECentral: @preconcurrency CBPeripheralDelegate {
    func peripheral(
        _ peripheral: CBPeripheral,
        didModifyServices invalidatedServices: [CBService]
    ) {
        guard peripheral.identifier == selectedPeripheralIdentifier else { return }
        let invalidated = invalidatedServices
            .map(\.uuid.uuidString)
            .joined(separator: ",")
        trace("GATT services invalidated=\(invalidated); destroying application session")
        cancelStateRead()
        clearDeviceOperations(reason: "GATT services invalidated")
        sessionReachedReady = false
        resetAuthentication()
        sessionState.reset()
        clearResolvedGATTProfile()
        connectionAfterDisconnect = (requestedDeviceID, discoveredName)
        userRequestedDisconnect = false
        connectionState = .connecting
        sessionState.beginConnection(expectedDeviceID: requestedDeviceID)
        central.cancelPeripheralConnection(peripheral)
        armConnectionTimeout(for: peripheral)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard peripheral.identifier == selectedPeripheralIdentifier else { return }
        if let error {
            trace("Service discovery failed: \(errorDescription(error))")
            connectionState = .failed(error.localizedDescription)
            return
        }
        trace("Services discovered count=\(peripheral.services?.count ?? 0)")
        guard let service = peripheral.services?.first(where: {
            $0.uuid == ProMistBLEProtocol.service
        }) else {
            trace("GATT rejected: ProMist service was not returned")
            connectionState = .failed("The ProMist BLE service is unavailable")
            return
        }
        peripheral.discoverCharacteristics(nil, for: service)
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didDiscoverCharacteristicsFor service: CBService,
        error: Error?
    ) {
        guard peripheral.identifier == selectedPeripheralIdentifier else { return }
        guard service.uuid == ProMistBLEProtocol.service else {
            trace("Ignoring characteristics for unrelated service \(service.uuid.uuidString)")
            return
        }
        if let error {
            trace("Characteristic discovery failed: \(errorDescription(error))")
            connectionState = .failed(error.localizedDescription)
            return
        }
        trace(
            "Characteristics discovered count=\(service.characteristics?.count ?? 0)"
        )
        service.characteristics?.forEach {
            characteristics[$0.uuid] = $0
        }
        let descriptions = characteristics.values.map {
            ProMistGATTCharacteristicDescription(
                uuid: $0.uuid,
                properties: $0.properties
            )
        }
        let profile = ProMistCapabilityResolver.resolve(
            deviceInformation: nil,
            descriptions: descriptions
        )
        gattProfile = profile
        capabilities = .none
        supportsRequiredSessionCharacteristics = profile.supportsRequiredSession
        guard supportsRequiredSessionCharacteristics else {
            capabilities = .none
            profile.validationErrors.forEach { trace("GATT rejected: \($0)") }
            connectionState = .failed("The ProMist BLE service is incomplete")
            return
        }
        ([
            ProMistBLEProtocol.state,
            ProMistBLEProtocol.response,
            ProMistBLEProtocol.security,
            ProMistBLEProtocol.logData,
            ProMistBLEProtocol.friendlyName,
            ProMistBLEProtocol.matterOnboarding
        ] + ProMistBLEProtocol.breezeSlots).forEach {
            if let characteristic = characteristics[$0] {
                peripheral.setNotifyValue(true, for: characteristic)
            }
        }
        ([
            ProMistBLEProtocol.logMetadata,
            ProMistBLEProtocol.friendlyName
        ] + ProMistBLEProtocol.breezeSlots).forEach {
            if let characteristic = characteristics[$0] {
                peripheral.readValue(for: characteristic)
            }
        }
        requestDeviceInformation()
        trace("GATT discovered; awaiting state and security subscriptions")
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        guard peripheral.identifier == selectedPeripheralIdentifier else { return }
        if let error {
            trace(
                "Value update failed uuid=\(characteristic.uuid.uuidString) \(errorDescription(error))"
            )
            if characteristic.uuid == ProMistBLEProtocol.information {
                requestDeviceInformation(afterNanoseconds: 250_000_000)
            } else if characteristic.uuid == ProMistBLEProtocol.state {
                requestDeviceState(afterNanoseconds: 250_000_000)
            } else if characteristic.uuid == ProMistBLEProtocol.friendlyName {
                operationTracker.finish(
                    .friendlyName,
                    reason: "name read failed"
                )
            } else if characteristic.uuid == ProMistBLEProtocol.logMetadata ||
                        characteristic.uuid == ProMistBLEProtocol.logData {
                finishDiagnosticRefresh(reason: "diagnostic read failed")
            }
            return
        }
        guard let data = characteristic.value else {
            trace("Value contained no data uuid=\(characteristic.uuid.uuidString)")
            if characteristic.uuid == ProMistBLEProtocol.information {
                requestDeviceInformation(afterNanoseconds: 250_000_000)
            }
            return
        }
        switch characteristic.uuid {
        case ProMistBLEProtocol.information:
            do {
                let information = try ProMistDeviceInformation(data: data)
                cancelInformationRead()
                deviceInformation = information
                gattProfile = ProMistCapabilityResolver.resolve(
                    deviceInformation: information,
                    descriptions: characteristics.values.map {
                        ProMistGATTCharacteristicDescription(
                            uuid: $0.uuid,
                            properties: $0.properties
                        )
                    }
                )
                capabilities = gattProfile.capabilities
                trace(
                    "Device information parsed protocol=\(information.protocolVersion) hardware=\(information.hardwareRevision) features=0x\(String(information.features.rawValue, radix: 16))"
                )
                finishReadySessionIfCapabilitiesResolved()
            } catch let validationError as ProMistGATTValidationError {
                trace("Device information rejected: \(validationError)")
                failSecurity("This fan uses unsupported device capability information.")
            } catch {
                trace("Device information rejected: \(error.localizedDescription)")
                failSecurity("This fan returned invalid device capability information.")
            }
        case ProMistBLEProtocol.state:
            if let state = ProMistDeviceState(data: data) {
                guard !sessionReachedReady || state.revision >= deviceState.revision else {
                    trace("State ignored: older revision")
                    return
                }
                deviceState = state
                if sessionReachedReady && isAuthenticated {
                    recordSessionSnapshot(state)
                }
                beginAuthenticationWhenSecurityIsReady(deviceID: state.deviceID)
                finishStateRefreshOperation()
                trace(
                    "State received revision=\(state.revision) power=\(state.power) fan=\(state.fanSpeed) fault=\(state.fault)"
                )
            } else {
                trace("State ignored: malformed")
            }
        case ProMistBLEProtocol.security:
            handleAuthenticationActions(authenticationEngine.receive(data))
        case ProMistBLEProtocol.response:
            protocolTransport?.receive(
                .packet(endpoint: .commandResponse, data: data)
            )
            if let (result, _, responseRequestID) = ProMistBLEProtocol.response(data) {
                lastResponse = result
                lastResponseRequestID = responseRequestID
                trace(
                    "Command response result=\(result.rawValue) request=\(responseRequestID)"
                )
                if result == .unauthorized,
                   deviceState.deviceID != 0,
                   authenticationEngine.hasCredential(
                       for: deviceState.deviceID
                   ) {
                    localDeviceLifecycle.requireRecovery(
                        for: deviceState.deviceID
                    )
                    failSecurity(
                        "The fan rejected its saved owner credential. Remove the saved pairing and provision it again."
                    )
                }
            }
        case ProMistBLEProtocol.logData:
            protocolTransport?.receive(
                .packet(endpoint: .diagnosticData, data: data)
            )
        case ProMistBLEProtocol.logMetadata:
            guard data.count == 20,
                  data[0] == ProMistBLEProtocol.version
            else {
                finishDiagnosticRefresh(reason: "invalid diagnostic metadata")
                trace("Diagnostic metadata rejected")
                return
            }
            trace(
                "Diagnostic metadata count=\(data[2]) capacity=\(data[1])"
            )
            if diagnosticRefreshRequested {
                diagnosticEngine?.start(expectedCount: Int(data[2]))
            }
        case ProMistBLEProtocol.friendlyName:
            if let name = String(data: data, encoding: .utf8),
               !name.isEmpty {
                discoveredName = name
                operationTracker.finish(
                    .friendlyName,
                    reason: "name confirmed"
                )
                trace("Friendly name received name=\(name)")
            } else {
                operationTracker.finish(
                    .friendlyName,
                    reason: "invalid name response"
                )
                trace("Friendly name rejected: invalid UTF-8")
            }
        case ProMistBLEProtocol.matterOnboarding:
            matterCoordinator.receiveOnboardingData(data)
        case let uuid where ProMistBLEProtocol.breezeSlots.contains(uuid):
            guard let slot = ProMistBLEProtocol.breezeSlots.firstIndex(of: uuid),
                  let update = applianceOperations.receiveBreezeSlot(
                    data,
                    characteristicSlot: slot
                  ) else { return }
            fanBreezeSlots[update.slot] = update.preset
        default:
            trace(
                "Value received uuid=\(characteristic.uuid.uuidString) bytes=\(data.count)"
            )
        }
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didWriteValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        guard peripheral.identifier == selectedPeripheralIdentifier else { return }
        if let error {
            trace(
                "Write failed uuid=\(characteristic.uuid.uuidString) \(errorDescription(error))"
            )
            let uuid = characteristic.uuid
            if uuid == ProMistBLEProtocol.friendlyName {
                operationTracker.finish(
                    .friendlyName,
                    reason: "name write failed"
                )
            } else if uuid == ProMistBLEProtocol.logRequest {
                finishDiagnosticRefresh(reason: "diagnostic request failed")
            }
        } else {
            trace("Write acknowledged uuid=\(characteristic.uuid.uuidString)")
            if ProMistBLEProtocol.breezeSlots.contains(characteristic.uuid) {
                peripheral.readValue(for: characteristic)
            }
        }
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateNotificationStateFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        guard peripheral.identifier == selectedPeripheralIdentifier else { return }
        if let error {
            trace(
                "Notification setup failed uuid=\(characteristic.uuid.uuidString) \(errorDescription(error))"
            )
            return
        }
        trace(
            "Notification state uuid=\(characteristic.uuid.uuidString) enabled=\(characteristic.isNotifying)"
        )
        if deviceState.deviceID != 0 {
            beginAuthenticationWhenSecurityIsReady(deviceID: deviceState.deviceID)
        }
        requestInitialStateWhenSubscriptionsAreReady()
    }

    private func requestInitialStateWhenSubscriptionsAreReady() {
        guard !sessionReachedReady,
              !isAuthenticated,
              authenticationEngine.deviceID == nil,
              !knownDeviceCoordinator.isReadScheduled(.state),
              characteristics[ProMistBLEProtocol.state]?.isNotifying == true,
              characteristics[ProMistBLEProtocol.security]?.isNotifying == true
        else { return }
        trace("State and security subscriptions ready; requesting device state")
        requestDeviceState()
    }
}
