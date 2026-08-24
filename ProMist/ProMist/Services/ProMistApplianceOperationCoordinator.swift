import Foundation

/// Owns semantic appliance operations above the request-correlated BLE command
/// engine. UUID lookup and characteristic writes remain transport concerns of
/// `ProMistBLECentral`.
@MainActor
final class ProMistApplianceOperationCoordinator {
    enum WriteEndpoint: Equatable {
        case friendlyName
        case breezeSlot(Int)
    }

    struct Session {
        let isAuthenticated: Bool
        let capabilities: ProMistCapabilities
        let supportsCustomBreezeSlots: Bool
    }

    struct BreezeUpdate: Equatable {
        let slot: Int
        let preset: BreezePreset?
    }

    struct Dependencies {
        var session: () -> Session
        var submitCommand: (ProMistBLEProtocol.Opcode, Int8) -> UInt32?
        var executeCommand: (
            ProMistBLEProtocol.Opcode,
            Int8
        ) async throws -> ProMistBLEProtocol.Result
        var write: (Data, WriteEndpoint) -> Bool
        var beginFriendlyNameOperation: () -> Void
        var trace: (String) -> Void
    }

    private let dependencies: Dependencies
    private var breezeTransfer = ProMistBreezeTransferState()

    init(dependencies: Dependencies) {
        self.dependencies = dependencies
    }

    func setPower(_ enabled: Bool) { send(.power, value: enabled ? 1 : 0) }
    func togglePower() { send(.togglePower, value: 0) }
    func setFanSpeed(_ speed: UInt8) {
        send(.fanSpeed, value: Int8(clamping: speed))
    }
    func setMist(_ enabled: Bool) { send(.mist, value: enabled ? 1 : 0) }
    func setBreeze(_ mode: UInt8) {
        send(.breeze, value: Int8(clamping: mode))
    }
    func setOscillation(_ mode: UInt8) {
        send(.oscillation, value: Int8(clamping: mode))
    }
    func jog(_ direction: Int8) { send(.direction, value: direction) }
    func home() { send(.direction, value: 0) }
    func setOscillationPosition(_ position: Int8) {
        send(.oscillationPosition, value: position)
    }
    func setTimer(minutes: UInt8?) {
        send(.timer, value: Int8(clamping: minutes ?? 0))
    }

    func installAndSelectBreeze(_ preset: BreezePreset, slot: Int) {
        let session = dependencies.session()
        guard session.supportsCustomBreezeSlots, (0..<3).contains(slot),
              let data = ProMistBLEProtocol.breezeProfile(preset, slot: slot)
        else { return }
        breezeTransfer.begin(slot: slot, presetID: preset.id)
        if !dependencies.write(data, .breezeSlot(slot)) {
            breezeTransfer.cancel()
        }
    }

    func clearBreezeSlot(_ slot: Int) {
        let session = dependencies.session()
        guard session.supportsCustomBreezeSlots, (0..<3).contains(slot),
              let data = ProMistBLEProtocol.breezeProfile(nil, slot: slot)
        else { return }
        breezeTransfer.cancel()
        _ = dependencies.write(data, .breezeSlot(slot))
    }

    func receiveBreezeSlot(
        _ data: Data,
        characteristicSlot: Int
    ) -> BreezeUpdate? {
        guard let decoded = ProMistBLEProtocol.breezeProfile(data),
              decoded.slot == characteristicSlot else {
            dependencies.trace("Breeze slot rejected: malformed profile")
            return nil
        }
        dependencies.trace(
            "Breeze slot \(decoded.slot + 1) received profile=\(decoded.preset?.name ?? "empty")"
        )
        if case .select(let mode) = breezeTransfer.receive(
            slot: decoded.slot,
            presetID: decoded.preset?.id
        ) {
            setBreeze(mode)
        }
        return BreezeUpdate(slot: decoded.slot, preset: decoded.preset)
    }

    func cancelBreezeTransfer() {
        breezeTransfer.cancel()
    }

    func clearFaults(currentFault: UInt8) async throws -> Bool {
        guard currentFault != 0 else { return false }
        guard canExecute(.clearFaults) else {
            throw ProMistControlError.deviceNotFound
        }
        // Preserve the foreground API's existing transaction error surface;
        // App Intent commands use the explicit mapping below.
        let result = try await dependencies.executeCommand(.clearFaults, 0)
        guard result == .success || result == .noChange else {
            throw ProMistControlError.rejected
        }
        return true
    }

    @discardableResult
    func setFriendlyName(_ name: String) -> Bool {
        let session = dependencies.session()
        guard session.isAuthenticated,
              session.capabilities.canRenameDevice else {
            dependencies.trace("Friendly-name write rejected: capability unavailable")
            return false
        }
        let normalized = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let bytes = Data(normalized.utf8)
        guard !bytes.isEmpty,
              bytes.count <= ProMistBLEProtocol.maximumFriendlyNameByteCount,
              !normalized.unicodeScalars.contains(where: {
                  CharacterSet.controlCharacters.contains($0)
              }) else {
            dependencies.trace("Friendly-name write rejected by local validation")
            return false
        }
        guard dependencies.write(bytes, .friendlyName) else { return false }
        dependencies.beginFriendlyNameOperation()
        dependencies.trace("Friendly-name write queued bytes=\(bytes.count)")
        return true
    }

    func executeControlCommand(_ command: ProMistControlCommand) async throws {
        let operation: (ProMistBLEProtocol.Opcode, Int8) = switch command {
        case .mist(let enabled): (.mist, enabled ? 1 : 0)
        case .breeze(let mode): (.breeze, Int8(clamping: mode))
        case .oscillationWidth(let mode): (.oscillation, Int8(clamping: mode))
        case .position(let position): (.oscillationPosition, position)
        case .jog(let direction): (.direction, direction)
        case .center: (.direction, 0)
        }
        guard canExecute(operation.0) else {
            throw ProMistControlError.deviceNotFound
        }
        let result = try await execute(operation.0, value: operation.1)
        guard result == .success || result == .noChange else {
            throw ProMistControlError.rejected
        }
    }

    @discardableResult
    private func send(
        _ opcode: ProMistBLEProtocol.Opcode,
        value: Int8
    ) -> UInt32? {
        guard canExecute(opcode) else {
            dependencies.trace(
                "Command ignored: session or capability unavailable opcode=\(opcode.rawValue)"
            )
            return nil
        }
        let requestID = dependencies.submitCommand(opcode, value)
        if let requestID {
            dependencies.trace(
                "Command queued opcode=\(opcode.rawValue) value=\(value) request=\(requestID)"
            )
        }
        return requestID
    }

    private func canExecute(_ opcode: ProMistBLEProtocol.Opcode) -> Bool {
        let session = dependencies.session()
        return session.isAuthenticated &&
            session.capabilities.supports(capability(for: opcode))
    }

    private func execute(
        _ opcode: ProMistBLEProtocol.Opcode,
        value: Int8
    ) async throws -> ProMistBLEProtocol.Result {
        do {
            return try await dependencies.executeCommand(opcode, value)
        } catch let error as ProMistBLETransactionError {
            switch error {
            case .timedOut:
                throw ProMistControlError.timedOut
            case .cancelled:
                throw CancellationError()
            case .transportUnavailable, .disconnected,
                 .malformedResponse, .unexpectedOpcode:
                throw ProMistControlError.deviceNotFound
            }
        }
    }

    private func capability(
        for opcode: ProMistBLEProtocol.Opcode
    ) -> ProMistCapability {
        switch opcode {
        case .power, .togglePower: .power
        case .fanSpeed: .fanSpeed
        case .mist: .mist
        case .breeze: .breezeModes
        case .oscillation: .oscillation
        case .direction, .oscillationPosition: .oscillationPosition
        case .timer: .timer
        case .clearFaults: .faultRecovery
        }
    }
}
