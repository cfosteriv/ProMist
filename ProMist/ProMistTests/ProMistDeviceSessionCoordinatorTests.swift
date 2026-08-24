import XCTest
@testable import ProMist

@MainActor
final class ProMistDeviceSessionCoordinatorTests: XCTestCase {
    private let deviceID: UInt64 = 0x123456

    func testFullyColdExecutionWaitsForAuthenticatedReadySession() async throws {
        let backend = ControlledSessionBackend()
        let coordinator = ProMistDeviceSessionCoordinator(backend: backend)

        let intent = Task { @MainActor in
            try await coordinator.setMist(deviceID: deviceID, enabled: true)
        }
        await Task.yield()

        XCTAssertEqual(backend.beginRequests, [deviceID])
        backend.transition(deviceID, to: .resolving)
        backend.transition(deviceID, to: .connecting)
        backend.transition(deviceID, to: .discovering)
        backend.transition(deviceID, to: .authenticating)
        XCTAssertTrue(backend.commands.isEmpty)
        backend.transition(deviceID, to: .ready)

        try await intent.value
        XCTAssertEqual(backend.commands, [.mist(true)])
    }

    func testMissingCredentialFailsBeforeConnectionStarts() async {
        let backend = ControlledSessionBackend()
        backend.credentialAvailable = false
        let coordinator = ProMistDeviceSessionCoordinator(backend: backend)

        await assertControlError(.authenticationUnavailable) {
            try await coordinator.center(deviceID: deviceID)
        }
        XCTAssertTrue(backend.beginRequests.isEmpty)
        XCTAssertTrue(backend.commands.isEmpty)
    }

    func testUnavailableDeviceTimesOutWithoutLeakingOperation() async {
        let backend = ControlledSessionBackend()
        let coordinator = ProMistDeviceSessionCoordinator(backend: backend)
        let intent = Task { @MainActor in
            try await coordinator.center(deviceID: deviceID)
        }
        await Task.yield()

        coordinator.expireReadiness(for: deviceID)
        await assertTaskError(.timedOut, task: intent)
        backend.transition(deviceID, to: .ready)
        XCTAssertTrue(backend.commands.isEmpty)
    }

    func testAuthenticationFailureCompletesIntentOnce() async {
        let backend = ControlledSessionBackend()
        let coordinator = ProMistDeviceSessionCoordinator(backend: backend)
        let intent = Task { @MainActor in
            try await coordinator.setBreeze(deviceID: deviceID, mode: 2)
        }
        await Task.yield()

        backend.transition(
            deviceID,
            to: .failed(.authenticationUnavailable)
        )
        backend.transition(deviceID, to: .ready)
        await assertTaskError(.authenticationUnavailable, task: intent)
        XCTAssertTrue(backend.commands.isEmpty)
    }

    func testDisconnectDuringAuthenticationCompletesOnce() async {
        let backend = ControlledSessionBackend()
        let coordinator = ProMistDeviceSessionCoordinator(backend: backend)
        let intent = Task { @MainActor in
            try await coordinator.setPosition(deviceID: deviceID, position: 2)
        }
        await Task.yield()

        backend.transition(deviceID, to: .authenticating)
        backend.transition(deviceID, to: .failed(.deviceNotFound))
        backend.transition(deviceID, to: .failed(.deviceNotFound))
        await assertTaskError(.deviceNotFound, task: intent)
        XCTAssertTrue(backend.commands.isEmpty)
    }

    func testConcurrentIntentsShareConnectionAndKeepCommandsIndependent() async throws {
        let backend = ControlledSessionBackend()
        let coordinator = ProMistDeviceSessionCoordinator(backend: backend)
        let first = Task { @MainActor in
            try await coordinator.setMist(deviceID: deviceID, enabled: true)
        }
        let second = Task { @MainActor in
            try await coordinator.setOscillationWidth(deviceID: deviceID, mode: 3)
        }
        await Task.yield()

        XCTAssertEqual(backend.beginRequests, [deviceID])
        backend.transition(deviceID, to: .ready)
        try await first.value
        try await second.value
        XCTAssertEqual(Set(backend.commands), [.mist(true), .oscillationWidth(3)])
    }

    private func assertControlError(
        _ expected: ProMistControlError,
        operation: () async throws -> Void
    ) async {
        do {
            try await operation()
            XCTFail("Expected \(expected)")
        } catch let error as ProMistControlError {
            XCTAssertEqual(error, expected)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    private func assertTaskError(
        _ expected: ProMistControlError,
        task: Task<Void, Error>
    ) async {
        await assertControlError(expected) { try await task.value }
    }
}

@MainActor
private final class ControlledSessionBackend: ProMistControlSessionBackend {
    var controlSessionEventHandler: ((UInt64, ProMistDeviceSessionStatus) -> Void)?
    var credentialAvailable = true
    private var statuses: [UInt64: ProMistDeviceSessionStatus] = [:]
    private(set) var beginRequests: [UInt64] = []
    private(set) var commands: [ProMistControlCommand] = []

    func controlSessionStatus(for deviceID: UInt64) -> ProMistDeviceSessionStatus {
        statuses[deviceID] ?? .idle
    }

    func hasOwnerCredential(for deviceID: UInt64) -> Bool {
        _ = deviceID
        return credentialAvailable
    }

    func beginControlSession(deviceID: UInt64, name: String) {
        _ = name
        beginRequests.append(deviceID)
        statuses[deviceID] = .resolving
    }

    func executeControlCommand(
        _ command: ProMistControlCommand,
        deviceID: UInt64
    ) async throws {
        guard statuses[deviceID] == .ready else {
            throw ProMistControlError.deviceNotFound
        }
        commands.append(command)
    }

    func transition(_ deviceID: UInt64, to status: ProMistDeviceSessionStatus) {
        statuses[deviceID] = status
        controlSessionEventHandler?(deviceID, status)
    }
}
