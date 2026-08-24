import Foundation

enum ProMistDeviceSessionStatus: Equatable, Sendable {
    case idle
    case resolving
    case connecting
    case discovering
    case authenticating
    case ready
    case bluetoothUnavailable
    case failed(ProMistControlError)
}

enum ProMistControlCommand: Hashable, Sendable {
    case mist(Bool)
    case breeze(UInt8)
    case oscillationWidth(UInt8)
    case position(Int8)
    case jog(Int8)
    case center
}

/// Narrow boundary used by App Intent orchestration. The production backend is
/// the single app-owned `ProMistBLECentral`; tests use an event-controlled fake.
@MainActor
protocol ProMistControlSessionBackend: AnyObject {
    var controlSessionEventHandler: ((UInt64, ProMistDeviceSessionStatus) -> Void)? {
        get set
    }
    func controlSessionStatus(for deviceID: UInt64) -> ProMistDeviceSessionStatus
    func hasOwnerCredential(for deviceID: UInt64) -> Bool
    func beginControlSession(deviceID: UInt64, name: String)
    func executeControlCommand(
        _ command: ProMistControlCommand,
        deviceID: UInt64
    ) async throws
}

/// Event-driven cold-session and command orchestration shared by foreground
/// composition and App Intents. No SwiftUI scene or polling loop is required.
@MainActor
final class ProMistDeviceSessionCoordinator: ProMistControlling {
    private struct Waiter {
        let continuation: CheckedContinuation<Void, Error>
        let timeout: Task<Void, Never>
    }

    private weak var backend: (any ProMistControlSessionBackend)?
    private let readinessTimeout: Duration
    private var waiters: [UInt64: [UUID: Waiter]] = [:]
    private var startingDevices = Set<UInt64>()

    init(
        backend: any ProMistControlSessionBackend,
        readinessTimeout: Duration = .seconds(15)
    ) {
        self.backend = backend
        self.readinessTimeout = readinessTimeout
        backend.controlSessionEventHandler = { [weak self] deviceID, status in
            self?.receive(deviceID: deviceID, status: status)
        }
    }

    func setMist(deviceID: UInt64, enabled: Bool) async throws {
        try await perform(.mist(enabled), deviceID: deviceID)
    }

    func setBreeze(deviceID: UInt64, mode: UInt8) async throws {
        try await perform(.breeze(mode), deviceID: deviceID)
    }

    func setOscillationWidth(deviceID: UInt64, mode: UInt8) async throws {
        try await perform(.oscillationWidth(mode), deviceID: deviceID)
    }

    func setPosition(deviceID: UInt64, position: Int8) async throws {
        try await perform(.position(position), deviceID: deviceID)
    }

    func jog(deviceID: UInt64, direction: Int8) async throws {
        try await perform(.jog(direction), deviceID: deviceID)
    }

    func center(deviceID: UInt64) async throws {
        try await perform(.center, deviceID: deviceID)
    }

    private func perform(
        _ command: ProMistControlCommand,
        deviceID: UInt64
    ) async throws {
        guard let backend else { throw ProMistControlError.deviceNotFound }
        try await readySession(for: deviceID, backend: backend)
        try Task.checkCancellation()
        try await backend.executeControlCommand(command, deviceID: deviceID)
    }

    private func readySession(
        for deviceID: UInt64,
        backend: any ProMistControlSessionBackend
    ) async throws {
        guard deviceID != 0 else { throw ProMistControlError.deviceNotFound }
        guard backend.hasOwnerCredential(for: deviceID) else {
            // App Intents target saved owned devices. They must never silently
            // fall into first-owner enrollment when the local key is missing.
            throw ProMistControlError.authenticationUnavailable
        }

        switch backend.controlSessionStatus(for: deviceID) {
        case .ready:
            return
        case .bluetoothUnavailable:
            throw ProMistControlError.bluetoothUnavailable
        case .failed(let error):
            throw error
        case .idle, .resolving, .connecting, .discovering, .authenticating:
            break
        }

        let waiterID = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let timeout = Task { @MainActor [weak self] in
                    guard let self else { return }
                    try? await Task.sleep(for: self.readinessTimeout)
                    guard !Task.isCancelled else { return }
                    self.finishWaiter(
                        waiterID,
                        deviceID: deviceID,
                        result: .failure(ProMistControlError.timedOut)
                    )
                }
                waiters[deviceID, default: [:]][waiterID] = Waiter(
                    continuation: continuation,
                    timeout: timeout
                )
                if startingDevices.insert(deviceID).inserted {
                    backend.beginControlSession(
                        deviceID: deviceID,
                        name: String(
                            format: "ProMist-%06llX",
                            deviceID & 0xFF_FFFF
                        )
                    )
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.finishWaiter(
                    waiterID,
                    deviceID: deviceID,
                    result: .failure(CancellationError())
                )
            }
        }
    }

    private func receive(
        deviceID: UInt64,
        status: ProMistDeviceSessionStatus
    ) {
        switch status {
        case .ready:
            startingDevices.remove(deviceID)
            finishAll(deviceID: deviceID, result: .success(()))
        case .bluetoothUnavailable:
            startingDevices.remove(deviceID)
            finishAll(
                deviceID: deviceID,
                result: .failure(ProMistControlError.bluetoothUnavailable)
            )
        case .failed(let error):
            startingDevices.remove(deviceID)
            finishAll(deviceID: deviceID, result: .failure(error))
        case .idle, .resolving, .connecting, .discovering, .authenticating:
            break
        }
    }

    /// Deterministic timeout hook for orchestration tests. Production timeouts
    /// call the same idempotent completion path from the scheduled task.
    func expireReadiness(for deviceID: UInt64) {
        startingDevices.remove(deviceID)
        finishAll(
            deviceID: deviceID,
            result: .failure(ProMistControlError.timedOut)
        )
    }

    private func finishAll(
        deviceID: UInt64,
        result: Result<Void, Error>
    ) {
        guard let pending = waiters.removeValue(forKey: deviceID) else { return }
        for waiter in pending.values {
            finish(waiter: waiter, result: result)
        }
    }

    private func finishWaiter(
        _ waiterID: UUID,
        deviceID: UInt64,
        result: Result<Void, Error>
    ) {
        guard let waiter = waiters[deviceID]?.removeValue(forKey: waiterID) else {
            return
        }
        if waiters[deviceID]?.isEmpty == true {
            waiters.removeValue(forKey: deviceID)
            startingDevices.remove(deviceID)
        }
        finish(waiter: waiter, result: result)
    }

    private func finish(
        waiter: Waiter,
        result: Result<Void, Error>
    ) {
        waiter.timeout.cancel()
        switch result {
        case .success:
            waiter.continuation.resume()
        case .failure(let error):
            waiter.continuation.resume(throwing: error)
        }
    }
}
