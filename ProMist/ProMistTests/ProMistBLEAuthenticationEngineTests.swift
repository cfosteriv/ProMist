import XCTest
@testable import ProMist

@MainActor
final class ProMistBLEAuthenticationEngineTests: XCTestCase {
    private final class CredentialBox {
        var values: [UInt64: Data] = [:]
        var deleted: [UInt64] = []
    }

    func testMissingCredentialStartsEnrollment() {
        let engine = makeEngine(box: CredentialBox())

        let actions = engine.begin(deviceID: 42)

        XCTAssertEqual(actions.first, .writeProvisioning(
            ProMistBLEProtocol.provisionRequest()
        ))
        XCTAssertEqual(engine.phase, .authenticating(deviceID: 42))
    }

    func testCredentialStartsChallengeWithGeneratedNonce() {
        let box = CredentialBox()
        box.values[42] = Data(repeating: 0xA5, count: 32)
        let nonce = Data(0..<32)
        let engine = makeEngine(box: box, nonce: nonce)

        let actions = engine.begin(deviceID: 42)

        XCTAssertEqual(actions.first, .writeSecurity(
            ProMistBLEProtocol.authenticationRequest(clientNonce: nonce)!
        ))
    }

    func testProvisionedCredentialIsSavedAndAccepted() {
        let box = CredentialBox()
        let engine = makeEngine(box: box)
        _ = engine.begin(deviceID: 42)
        let key = Data(repeating: 0x3C, count: 32)
        let packet = Data([
            ProMistBLEProtocol.SecurityMessage.provisioned.rawValue,
            ProMistBLEProtocol.version
        ]) + key

        XCTAssertEqual(
            engine.receive(packet),
            [.authenticationAccepted(deviceID: 42)]
        )
        XCTAssertEqual(box.values[42], key)
        XCTAssertTrue(engine.isAuthenticated)
    }

    func testRejectedCredentialAttemptsPhysicalReprovisionOnlyOnce() {
        let box = CredentialBox()
        box.values[42] = Data(repeating: 0xA5, count: 32)
        let engine = makeEngine(box: box)
        _ = engine.begin(deviceID: 42)
        let rejection = Data([
            ProMistBLEProtocol.SecurityMessage.authenticationResult.rawValue,
            ProMistBLEProtocol.version,
            1
        ])

        XCTAssertEqual(engine.receive(rejection).first, .writeProvisioning(
            ProMistBLEProtocol.provisionRequest()
        ))
        let second = engine.receive(rejection)
        XCTAssertTrue(second.contains(.recoveryRequired(deviceID: 42)))
        XCTAssertTrue(second.contains(.failed(
            "Owner authentication failed. Use the physical recovery gesture if this phone is no longer the owner."
        )))
    }

    func testOwnershipResetDeletesCredentialAfterDeviceConfirmation() throws {
        let box = CredentialBox()
        box.values[42] = Data(repeating: 0xA5, count: 32)
        let engine = makeEngine(box: box)
        _ = engine.begin(deviceID: 42)
        _ = engine.receive(Data([
            ProMistBLEProtocol.SecurityMessage.authenticationResult.rawValue,
            ProMistBLEProtocol.version,
            0
        ]))
        XCTAssertNotNil(engine.beginOwnershipReset(deviceID: 42))

        let actions = engine.receive(Data([
            ProMistBLEProtocol.SecurityMessage.authenticationResult.rawValue,
            ProMistBLEProtocol.version,
            0
        ]))

        XCTAssertEqual(actions.first, .ownershipResetCompleted(deviceID: 42))
        XCTAssertEqual(box.deleted, [42])
        XCTAssertNil(box.values[42])
    }

    func testTimeoutDistinguishesAuthenticationAndCapabilityResolution() async {
        let box = CredentialBox()
        let engine = makeEngine(box: box, timeout: .milliseconds(10))
        var events: [ProMistBLEAuthenticationEngine.Action] = []
        engine.eventHandler = { events.append($0) }
        _ = engine.begin(deviceID: 42)

        try? await Task.sleep(for: .milliseconds(30))
        XCTAssertTrue(events.contains(.timedOut(
            deviceID: 42,
            phase: .authentication
        )))

        box.values[42] = Data(repeating: 0xA5, count: 32)
        events.removeAll()
        _ = engine.begin(deviceID: 42)
        _ = engine.receive(Data([
            ProMistBLEProtocol.SecurityMessage.authenticationResult.rawValue,
            ProMistBLEProtocol.version,
            0
        ]))
        try? await Task.sleep(for: .milliseconds(30))
        XCTAssertTrue(events.contains(.timedOut(
            deviceID: 42,
            phase: .capabilityResolution
        )))
    }

    private func makeEngine(
        box: CredentialBox,
        nonce: Data = Data(repeating: 7, count: 32),
        timeout: Duration = .seconds(30)
    ) -> ProMistBLEAuthenticationEngine {
        ProMistBLEAuthenticationEngine(
            credentials: .init(
                load: { box.values[$0] },
                save: {
                    box.values[$1] = $0
                    return true
                },
                delete: {
                    box.values.removeValue(forKey: $0)
                    box.deleted.append($0)
                }
            ),
            timeout: timeout,
            nonceGenerator: { nonce }
        )
    }
}
