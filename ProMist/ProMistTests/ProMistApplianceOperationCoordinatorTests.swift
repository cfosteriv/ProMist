import XCTest
@testable import ProMist

@MainActor
final class ProMistApplianceOperationCoordinatorTests: XCTestCase {
    private final class Box {
        var session = ProMistApplianceOperationCoordinator.Session(
            isAuthenticated: true,
            capabilities: .none,
            supportsCustomBreezeSlots: false
        )
        var submitted: [(ProMistBLEProtocol.Opcode, Int8)] = []
        var writes: [(Data, ProMistApplianceOperationCoordinator.WriteEndpoint)] = []
        var friendlyNameOperations = 0
        var executeResult: ProMistBLEProtocol.Result = .success
        var executeError: Error?
    }

    func testSemanticCommandRequiresAuthenticationAndCapability() {
        let box = Box()
        let coordinator = makeCoordinator(box)

        coordinator.setPower(true)
        XCTAssertTrue(box.submitted.isEmpty)

        box.session = .init(
            isAuthenticated: true,
            capabilities: capabilities(power: true),
            supportsCustomBreezeSlots: false
        )
        coordinator.setPower(true)
        XCTAssertEqual(box.submitted.first?.0, .power)
        XCTAssertEqual(box.submitted.first?.1, 1)
    }

    func testFriendlyNameValidationAndOperationLifecycle() {
        let box = Box()
        var capabilities = ProMistCapabilities.none
        capabilities.canRenameDevice = true
        box.session = .init(
            isAuthenticated: true,
            capabilities: capabilities,
            supportsCustomBreezeSlots: false
        )
        let coordinator = makeCoordinator(box)

        XCTAssertFalse(coordinator.setFriendlyName("   "))
        XCTAssertFalse(coordinator.setFriendlyName("bad\u{0007}name"))
        XCTAssertTrue(coordinator.setFriendlyName(" Porch "))

        XCTAssertEqual(String(data: box.writes[0].0, encoding: .utf8), "Porch")
        XCTAssertEqual(box.writes[0].1, .friendlyName)
        XCTAssertEqual(box.friendlyNameOperations, 1)
    }

    func testBreezeSelectionWaitsForMatchingProfileAcknowledgment() {
        let box = Box()
        var capabilities = ProMistCapabilities.none
        capabilities.canUseBreezeModes = true
        box.session = .init(
            isAuthenticated: true,
            capabilities: capabilities,
            supportsCustomBreezeSlots: true
        )
        let coordinator = makeCoordinator(box)
        let preset = BreezePreset(
            id: 7,
            name: "Porch",
            cycleSeconds: 15,
            keyframes: [
                .init(second: 0, level: 3),
                .init(second: 5, level: 5),
                .init(second: 10, level: 3)
            ]
        )
        coordinator.installAndSelectBreeze(preset, slot: 1)
        let wire = ProMistBLEProtocol.breezeProfile(preset, slot: 1)!

        let update = coordinator.receiveBreezeSlot(wire, characteristicSlot: 1)

        XCTAssertEqual(update, .init(slot: 1, preset: preset))
        XCTAssertEqual(box.writes.first?.1, .breezeSlot(1))
        XCTAssertEqual(box.submitted.last?.0, .breeze)
        XCTAssertEqual(box.submitted.last?.1, 5)
    }

    func testClearFaultsAndControlCommandsMapResultsAndErrors() async throws {
        let box = Box()
        var capabilities = ProMistCapabilities.none
        capabilities.canClearFaults = true
        capabilities.canPositionOscillation = true
        box.session = .init(
            isAuthenticated: true,
            capabilities: capabilities,
            supportsCustomBreezeSlots: false
        )
        let coordinator = makeCoordinator(box)

        let cleared = try await coordinator.clearFaults(currentFault: 3)
        XCTAssertTrue(cleared)
        try await coordinator.executeControlCommand(.center)
        XCTAssertEqual(box.submitted.suffix(2).map(\.0), [.clearFaults, .direction])
        XCTAssertEqual(box.submitted.last?.1, 0)

        box.executeError = ProMistBLETransactionError.timedOut
        do {
            try await coordinator.executeControlCommand(.center)
            XCTFail("Expected mapped timeout")
        } catch {
            XCTAssertEqual(error as? ProMistControlError, .timedOut)
        }
    }

    private func makeCoordinator(
        _ box: Box
    ) -> ProMistApplianceOperationCoordinator {
        ProMistApplianceOperationCoordinator(
            dependencies: .init(
                session: { box.session },
                submitCommand: {
                    box.submitted.append(($0, $1))
                    return UInt32(box.submitted.count)
                },
                executeCommand: {
                    box.submitted.append(($0, $1))
                    if let error = box.executeError { throw error }
                    return box.executeResult
                },
                write: {
                    box.writes.append(($0, $1))
                    return true
                },
                beginFriendlyNameOperation: {
                    box.friendlyNameOperations += 1
                },
                trace: { _ in }
            )
        )
    }

    private func capabilities(power: Bool) -> ProMistCapabilities {
        var result = ProMistCapabilities.none
        result.canControlPower = power
        return result
    }
}
