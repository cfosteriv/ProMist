// Semantic projection of a ProMist device-information manifest and its
// discovered GATT transport. SwiftUI never inspects CoreBluetooth directly.
@preconcurrency import CoreBluetooth
import Foundation

struct ProMistFeatureSet: OptionSet, Equatable, Sendable {
    let rawValue: UInt16

    static let fanControl = Self(rawValue: 1 << 0)
    static let mist = Self(rawValue: 1 << 1)
    static let oscillation = Self(rawValue: 1 << 2)
    static let positioning = Self(rawValue: 1 << 3)
    static let breezeModes = Self(rawValue: 1 << 4)
    static let diagnostics = Self(rawValue: 1 << 5)
    static let rename = Self(rawValue: 1 << 6)
    static let matter = Self(rawValue: 1 << 7)
    static let timer = Self(rawValue: 1 << 8)
    static let faultRecovery = Self(rawValue: 1 << 9)

    /// Bits 10...15 are reserved for future hardware capabilities. Unknown bits
    /// remain in `rawValue` so newer manifests can be handled safely.
    static let currentDevice: Self = [
        .fanControl, .mist, .oscillation, .positioning, .breezeModes,
        .diagnostics, .rename, .matter, .timer, .faultRecovery
    ]
}

struct ProMistDeviceInformation: Equatable, Sendable {
    static let minimumLength = 16

    let protocolVersion: UInt8
    let hardwareRevision: UInt8
    let features: ProMistFeatureSet

    init(data: Data) throws {
        guard data.count >= Self.minimumLength else {
            throw ProMistGATTValidationError.invalidDeviceInformation
        }
        let version = data[0]
        guard version == ProMistBLEProtocol.version else {
            throw ProMistGATTValidationError.unsupportedProtocolVersion(version)
        }
        protocolVersion = version
        hardwareRevision = data[1]
        features = ProMistFeatureSet(
            rawValue: UInt16(data[2]) | (UInt16(data[3]) << 8)
        )
    }

    static let currentPrototype = ProMistDeviceInformation(
        protocolVersion: ProMistBLEProtocol.version,
        hardwareRevision: 1,
        features: .currentDevice
    )

    init(
        protocolVersion: UInt8,
        hardwareRevision: UInt8,
        features: ProMistFeatureSet
    ) {
        self.protocolVersion = protocolVersion
        self.hardwareRevision = hardwareRevision
        self.features = features
    }
}

enum ProMistCapability: CaseIterable, Sendable {
    case power
    case fanSpeed
    case mist
    case breezeModes
    case oscillation
    case oscillationPosition
    case diagnostics
    case renameDevice
    case matterOnboarding
    case timer
    case faultRecovery
}

struct ProMistCapabilities: Equatable, Sendable {
    var canControlPower = false
    var canControlFanSpeed = false
    var canControlMist = false
    var canUseBreezeModes = false
    var canControlOscillation = false
    var canPositionOscillation = false
    var canReadDiagnostics = false
    var canRenameDevice = false
    var canProvideMatterOnboarding = false
    var canSetTimer = false
    var canClearFaults = false

    static let none = ProMistCapabilities()

    func supports(_ capability: ProMistCapability) -> Bool {
        switch capability {
        case .power: canControlPower
        case .fanSpeed: canControlFanSpeed
        case .mist: canControlMist
        case .breezeModes: canUseBreezeModes
        case .oscillation: canControlOscillation
        case .oscillationPosition: canPositionOscillation
        case .diagnostics: canReadDiagnostics
        case .renameDevice: canRenameDevice
        case .matterOnboarding: canProvideMatterOnboarding
        case .timer: canSetTimer
        case .faultRecovery: canClearFaults
        }
    }
}

struct ProMistGATTCharacteristicDescription: Equatable, Sendable {
    let uuid: CBUUID
    let properties: CBCharacteristicProperties
}

struct ProMistGATTCharacteristicRequirement: Equatable, Sendable {
    let uuid: CBUUID
    let requiredProperties: CBCharacteristicProperties
}

enum ProMistGATTValidationError: Error, Equatable, CustomStringConvertible {
    case missingRequiredCharacteristic(CBUUID)
    case missingRequiredProperties(
        uuid: CBUUID,
        required: CBCharacteristicProperties,
        actual: CBCharacteristicProperties
    )
    case invalidDeviceInformation
    case unsupportedProtocolVersion(UInt8)

    var description: String {
        switch self {
        case .missingRequiredCharacteristic(let uuid):
            "missing characteristic \(uuid.uuidString)"
        case let .missingRequiredProperties(uuid, required, actual):
            "characteristic \(uuid.uuidString) requires 0x\(String(required.rawValue, radix: 16)); actual 0x\(String(actual.rawValue, radix: 16))"
        case .invalidDeviceInformation:
            "invalid device-information payload"
        case .unsupportedProtocolVersion(let version):
            "unsupported device-information protocol version \(version)"
        }
    }
}

struct ProMistGATTProfile: Equatable, Sendable {
    let capabilities: ProMistCapabilities
    let supportsRequiredSession: Bool
    let validationErrors: [ProMistGATTValidationError]

    static let unresolved = ProMistGATTProfile(
        capabilities: .none,
        supportsRequiredSession: false,
        validationErrors: []
    )
}

enum ProMistCapabilityResolver {
    private static func requirement(
        _ uuid: CBUUID,
        _ properties: CBCharacteristicProperties
    ) -> ProMistGATTCharacteristicRequirement {
        ProMistGATTCharacteristicRequirement(
            uuid: uuid,
            requiredProperties: properties
        )
    }

    /// Mandatory owner-session transport. A missing UUID or property prevents
    /// the session from becoming ready.
    static let requiredSessionRequirements = [
        requirement(ProMistBLEProtocol.information, .read),
        requirement(ProMistBLEProtocol.security, [.write, .notify]),
        requirement(ProMistBLEProtocol.state, [.read, .notify]),
        requirement(ProMistBLEProtocol.command, .write),
        requirement(ProMistBLEProtocol.response, .notify),
        requirement(ProMistBLEProtocol.provisioning, .write)
    ]

    static let requiredSessionCharacteristics = Set(
        requiredSessionRequirements.map(\.uuid)
    )

    private static let commandTransportRequirements = [
        requirement(ProMistBLEProtocol.command, .write),
        requirement(ProMistBLEProtocol.response, .notify),
        requirement(ProMistBLEProtocol.state, [.read, .notify])
    ]

    private static let requirements: [
        ProMistCapability: [ProMistGATTCharacteristicRequirement]
    ] = [
        .power: commandTransportRequirements,
        .fanSpeed: commandTransportRequirements,
        .mist: commandTransportRequirements,
        .breezeModes: commandTransportRequirements,
        .oscillation: commandTransportRequirements,
        .oscillationPosition: commandTransportRequirements,
        .timer: commandTransportRequirements,
        .faultRecovery: commandTransportRequirements,
        .diagnostics: [
            requirement(ProMistBLEProtocol.logMetadata, .read),
            requirement(ProMistBLEProtocol.logRequest, .write),
            requirement(ProMistBLEProtocol.logData, .notify)
        ],
        .renameDevice: [
            requirement(
                ProMistBLEProtocol.friendlyName,
                [.read, .write, .notify]
            )
        ],
        .matterOnboarding: [
            requirement(ProMistBLEProtocol.matterOnboarding, [.write, .notify])
        ]
    ]

    static let currentGATTCharacteristics: [
        CBUUID: CBCharacteristicProperties
    ] = [
        ProMistBLEProtocol.information: .read,
        ProMistBLEProtocol.security: [.write, .notify],
        ProMistBLEProtocol.state: [.read, .notify],
        ProMistBLEProtocol.command: .write,
        ProMistBLEProtocol.response: [.read, .notify],
        ProMistBLEProtocol.logMetadata: .read,
        ProMistBLEProtocol.logRequest: .write,
        ProMistBLEProtocol.logData: .notify,
        ProMistBLEProtocol.friendlyName: [.read, .write, .notify],
        ProMistBLEProtocol.matterOnboarding: [.write, .notify],
        ProMistBLEProtocol.provisioning: .write,
        ProMistBLEProtocol.breezeSlot0: [.read, .write, .notify],
        ProMistBLEProtocol.breezeSlot1: [.read, .write, .notify],
        ProMistBLEProtocol.breezeSlot2: [.read, .write, .notify]
    ]

    static func requiredCharacteristics(
        for capability: ProMistCapability
    ) -> Set<CBUUID> {
        Set(requirements[capability, default: []].map(\.uuid))
    }

    static func resolve(
        deviceInformation: ProMistDeviceInformation?,
        characteristics: [CBUUID: CBCharacteristicProperties]
    ) -> ProMistGATTProfile {
        let validationErrors = requiredSessionRequirements.compactMap {
            validationError(for: $0, in: characteristics)
        }
        let supportsRequiredSession = validationErrors.isEmpty
        guard supportsRequiredSession, let deviceInformation else {
            return ProMistGATTProfile(
                capabilities: .none,
                supportsRequiredSession: supportsRequiredSession,
                validationErrors: validationErrors
            )
        }

        func transportSupports(_ capability: ProMistCapability) -> Bool {
            requirements[capability, default: []].allSatisfy {
                validationError(for: $0, in: characteristics) == nil
            }
        }
        let features = deviceInformation.features
        let fan = features.contains(.fanControl)
        let oscillation = features.contains(.oscillation)

        return ProMistGATTProfile(
            capabilities: ProMistCapabilities(
                canControlPower: fan && transportSupports(.power),
                canControlFanSpeed: fan && transportSupports(.fanSpeed),
                canControlMist: features.contains(.mist) && transportSupports(.mist),
                canUseBreezeModes: features.contains(.breezeModes) && transportSupports(.breezeModes),
                canControlOscillation: oscillation && transportSupports(.oscillation),
                canPositionOscillation: oscillation && features.contains(.positioning) && transportSupports(.oscillationPosition),
                canReadDiagnostics: features.contains(.diagnostics) && transportSupports(.diagnostics),
                canRenameDevice: features.contains(.rename) && transportSupports(.renameDevice),
                canProvideMatterOnboarding: features.contains(.matter) && transportSupports(.matterOnboarding),
                canSetTimer: features.contains(.timer) && transportSupports(.timer),
                canClearFaults: features.contains(.faultRecovery) && transportSupports(.faultRecovery)
            ),
            supportsRequiredSession: true,
            validationErrors: []
        )
    }

    static func resolve(
        deviceInformation: ProMistDeviceInformation?,
        descriptions: [ProMistGATTCharacteristicDescription]
    ) -> ProMistGATTProfile {
        resolve(
            deviceInformation: deviceInformation,
            characteristics: Dictionary(
                descriptions.map { ($0.uuid, $0.properties) },
                uniquingKeysWith: { _, latest in latest }
            )
        )
    }

    private static func validationError(
        for requirement: ProMistGATTCharacteristicRequirement,
        in characteristics: [CBUUID: CBCharacteristicProperties]
    ) -> ProMistGATTValidationError? {
        guard let actual = characteristics[requirement.uuid] else {
            return .missingRequiredCharacteristic(requirement.uuid)
        }
        guard actual.contains(requirement.requiredProperties) else {
            return .missingRequiredProperties(
                uuid: requirement.uuid,
                required: requirement.requiredProperties,
                actual: actual
            )
        }
        return nil
    }
}
