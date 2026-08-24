// Capability-policy tests use normalized UUID/property values and require no
// CBPeripheral or physical BLE hardware.
import CoreBluetooth
import Foundation
import XCTest
@testable import ProMist

@MainActor
final class ProMistCapabilitiesTests: XCTestCase {
    func testCurrentDeviceInformationFixtureIsVersionedAndLittleEndian() throws {
        // Canonical fixture: 0201ff03080706050403020100020000
        let data = Data([
            0x02, 0x01, 0xFF, 0x03, 0x08, 0x07, 0x06, 0x05,
            0x04, 0x03, 0x02, 0x01, 0x00, 0x02, 0x00, 0x00
        ])
        let information = try ProMistDeviceInformation(data: data)

        XCTAssertEqual(information.protocolVersion, ProMistBLEProtocol.version)
        XCTAssertEqual(information.hardwareRevision, 1)
        XCTAssertEqual(information.features, .currentDevice)
    }

    func testMalformedAndUnsupportedInformationFailPredictably() {
        XCTAssertThrowsError(try ProMistDeviceInformation(data: Data([2, 1, 0]))) {
            XCTAssertEqual($0 as? ProMistGATTValidationError, .invalidDeviceInformation)
        }
        var futureVersion = Data(repeating: 0, count: 16)
        futureVersion[0] = 3
        futureVersion[1] = 1
        XCTAssertThrowsError(try ProMistDeviceInformation(data: futureVersion)) {
            XCTAssertEqual(
                $0 as? ProMistGATTValidationError,
                .unsupportedProtocolVersion(3)
            )
        }
    }

    func testUnknownFutureFeatureBitsArePreservedAndIgnored() throws {
        let information = try manifest(.currentDevice.union(.init(rawValue: 1 << 15)))
        let profile = resolve(information: information)

        XCTAssertEqual(information.features.rawValue, 0x83FF)
        XCTAssertTrue(profile.supportsRequiredSession)
        XCTAssertTrue(profile.capabilities.canControlMist)
        XCTAssertTrue(profile.capabilities.canReadDiagnostics)
    }

    func testFullCurrentDeviceSupportsEveryCurrentControl() throws {
        let profile = resolve(information: try manifest(.currentDevice))

        XCTAssertTrue(profile.supportsRequiredSession)
        for capability in ProMistCapability.allCases {
            XCTAssertTrue(
                profile.capabilities.supports(capability),
                "Expected current manifest and GATT table to support \(capability)"
            )
        }
    }

    func testGenericCommandTransportDoesNotImplyMistHardware() throws {
        let features = ProMistFeatureSet.currentDevice.subtracting(.mist)
        let profile = resolve(information: try manifest(features))

        XCTAssertFalse(profile.capabilities.canControlMist)
        XCTAssertTrue(profile.capabilities.canControlPower)
        XCTAssertTrue(profile.capabilities.canControlFanSpeed)
    }

    func testTimerRequiresItsSemanticFeatureFlag() throws {
        let withoutTimer = resolve(
            information: try manifest(.currentDevice.subtracting(.timer))
        )

        XCTAssertFalse(withoutTimer.capabilities.canSetTimer)
        XCTAssertTrue(withoutTimer.capabilities.canControlPower)
    }

    func testFaultRecoveryRequiresItsSemanticFeatureFlag() throws {
        let withoutRecovery = resolve(
            information: try manifest(.currentDevice.subtracting(.faultRecovery))
        )

        XCTAssertFalse(withoutRecovery.capabilities.canClearFaults)
        XCTAssertTrue(withoutRecovery.capabilities.canReadDiagnostics)
    }

    func testPositioningRequiresSemanticPositioningAndOscillation() throws {
        let basic = resolve(information: try manifest([
            .fanControl, .oscillation
        ]))
        XCTAssertTrue(basic.capabilities.canControlOscillation)
        XCTAssertFalse(basic.capabilities.canPositionOscillation)

        let positioningWithoutOscillation = resolve(information: try manifest([
            .fanControl, .positioning
        ]))
        XCTAssertFalse(positioningWithoutOscillation.capabilities.canControlOscillation)
        XCTAssertFalse(positioningWithoutOscillation.capabilities.canPositionOscillation)
    }

    func testDiagnosticsRequireSemanticFlagAndCompleteTransport() throws {
        let withoutFlag = resolve(
            information: try manifest(.currentDevice.subtracting(.diagnostics))
        )
        XCTAssertFalse(withoutFlag.capabilities.canReadDiagnostics)

        var missingTransport = ProMistCapabilityResolver.currentGATTCharacteristics
        missingTransport.removeValue(forKey: ProMistBLEProtocol.logData)
        let withoutTransport = resolve(
            information: try manifest(.currentDevice),
            characteristics: missingTransport
        )
        XCTAssertTrue(withoutTransport.supportsRequiredSession)
        XCTAssertFalse(withoutTransport.capabilities.canReadDiagnostics)
        XCTAssertTrue(withoutTransport.capabilities.canControlFanSpeed)
    }

    func testOptionalWrongPropertiesHideOnlyThatCapability() throws {
        var characteristics = ProMistCapabilityResolver.currentGATTCharacteristics
        characteristics[ProMistBLEProtocol.logData] = .read

        let profile = resolve(
            information: try manifest(.currentDevice),
            characteristics: characteristics
        )
        XCTAssertTrue(profile.supportsRequiredSession)
        XCTAssertFalse(profile.capabilities.canReadDiagnostics)
        XCTAssertTrue(profile.capabilities.canRenameDevice)
    }

    func testEveryMandatoryCharacteristicIsRequiredForReadySession() throws {
        for missing in ProMistCapabilityResolver.requiredSessionCharacteristics {
            var characteristics = ProMistCapabilityResolver.currentGATTCharacteristics
            characteristics.removeValue(forKey: missing)
            let profile = resolve(
                information: try manifest(.currentDevice),
                characteristics: characteristics
            )

            XCTAssertFalse(profile.supportsRequiredSession)
            XCTAssertEqual(profile.capabilities, .none)
            XCTAssertTrue(profile.validationErrors.contains(
                .missingRequiredCharacteristic(missing)
            ))
        }
    }

    func testMandatoryCharacteristicPropertiesAreValidated() throws {
        let invalid: [(CBUUID, CBCharacteristicProperties)] = [
            (ProMistBLEProtocol.command, .read),
            (ProMistBLEProtocol.state, .read),
            (ProMistBLEProtocol.security, .notify),
            (ProMistBLEProtocol.response, .read),
            (ProMistBLEProtocol.information, .notify)
        ]

        for (uuid, properties) in invalid {
            var characteristics = ProMistCapabilityResolver.currentGATTCharacteristics
            characteristics[uuid] = properties
            let profile = resolve(
                information: try manifest(.currentDevice),
                characteristics: characteristics
            )

            XCTAssertFalse(profile.supportsRequiredSession)
            XCTAssertEqual(profile.capabilities, .none)
            guard case let .missingRequiredProperties(errorUUID, _, actual) =
                    profile.validationErrors.first else {
                return XCTFail("Expected a property validation error for \(uuid)")
            }
            XCTAssertEqual(errorUUID, uuid)
            XCTAssertEqual(actual, properties)
        }
    }

    func testExtraCharacteristicPropertiesAreAllowed() throws {
        var characteristics = ProMistCapabilityResolver.currentGATTCharacteristics
        characteristics[ProMistBLEProtocol.state] = [.read, .notify, .indicate]

        let profile = resolve(
            information: try manifest(.currentDevice),
            characteristics: characteristics
        )
        XCTAssertTrue(profile.supportsRequiredSession)
        XCTAssertTrue(profile.capabilities.canControlFanSpeed)
    }

    func testDescriptionsNormalizeWithoutCBCharacteristicMocks() throws {
        let descriptions = ProMistCapabilityResolver.currentGATTCharacteristics.map {
            ProMistGATTCharacteristicDescription(uuid: $0.key, properties: $0.value)
        }
        let profile = ProMistCapabilityResolver.resolve(
            deviceInformation: try manifest(.currentDevice),
            descriptions: descriptions
        )

        XCTAssertTrue(profile.supportsRequiredSession)
        XCTAssertTrue(profile.capabilities.canControlMist)
    }

    func testCapabilitiesRemainUnresolvedUntilInformationIsParsed() {
        let profile = ProMistCapabilityResolver.resolve(
            deviceInformation: nil,
            characteristics: ProMistCapabilityResolver.currentGATTCharacteristics
        )

        XCTAssertTrue(profile.supportsRequiredSession)
        XCTAssertEqual(profile.capabilities, .none)
    }

    private func manifest(
        _ features: ProMistFeatureSet
    ) throws -> ProMistDeviceInformation {
        var data = Data([
            ProMistBLEProtocol.version,
            1,
            UInt8(truncatingIfNeeded: features.rawValue),
            UInt8(truncatingIfNeeded: features.rawValue >> 8)
        ])
        data += Data(repeating: 0, count: 12)
        return try ProMistDeviceInformation(data: data)
    }

    private func resolve(
        information: ProMistDeviceInformation,
        characteristics: [CBUUID: CBCharacteristicProperties]? = nil
    ) -> ProMistGATTProfile {
        ProMistCapabilityResolver.resolve(
            deviceInformation: information,
            characteristics: characteristics ??
                ProMistCapabilityResolver.currentGATTCharacteristics
        )
    }
}
