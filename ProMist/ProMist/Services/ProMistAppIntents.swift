// Siri and Shortcuts surface for ProMist-specific actions. Every intent routes
// through ProMistControlling so automation shares the app's auth/timeout policy.
import AppIntents

protocol ProMistDeviceIntent: AppIntent {}

extension ProMistDeviceIntent {
    /// Intents resolve or create the application service directly and never
    /// depend on a visible SwiftUI hierarchy.
    static var openAppWhenRun: Bool { false }
}

enum ProMistBreeze: Int, AppEnum {
    case off, windyDay, highsAndLows, lowsAndHighs
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Breeze")
    static let caseDisplayRepresentations: [Self: DisplayRepresentation] = [
        .off: "Off",
        .windyDay: "Windy Day",
        .highsAndLows: "Highs and Lows",
        .lowsAndHighs: "Lows and Highs"
    ]
}

enum ProMistMistState: Int, AppEnum {
    case off, on
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Misting")
    static let caseDisplayRepresentations: [Self: DisplayRepresentation] = [
        .off: "Off", .on: "On"
    ]
}

enum ProMistOscillationWidth: Int, AppEnum {
    case off, narrow, medium, wide
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Rotation")
    static let caseDisplayRepresentations: [Self: DisplayRepresentation] = [
        .off: "Off",
        .narrow: "Low (45 degrees)",
        .medium: "Medium (90 degrees)",
        .wide: "High (180 degrees)"
    ]

    var spokenName: String {
        switch self {
        case .off: "off"
        case .narrow: "low at 45 degrees"
        case .medium: "medium at 90 degrees"
        case .wide: "high at 180 degrees"
        }
    }
}

enum ProMistDirection: Int, AppEnum {
    case forward, left, right
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Direction")
    static let caseDisplayRepresentations: [Self: DisplayRepresentation] = [
        .forward: "Forward", .left: "Left", .right: "Right"
    ]
}

enum ProMistJogDirection: Int, AppEnum {
    case left, right
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Move Direction")
    static let caseDisplayRepresentations: [Self: DisplayRepresentation] = [
        .left: "Left", .right: "Right"
    ]
}

struct SetProMistMistIntent: ProMistDeviceIntent {
    static let title: LocalizedStringResource = "Set ProMist Mist"
    @Parameter(title: "Device") var device: ProMistDeviceEntity
    @Parameter(title: "Misting") var misting: ProMistMistState
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let control = await ProMistControlRegistry.shared.resolve()
        try await control.setMist(deviceID: device.deviceID, enabled: misting == .on)
        return .result(dialog: "Misting is \(misting == .on ? "on" : "off") on \(device.name).")
    }
}

struct CenterProMistIntent: ProMistDeviceIntent {
    static let title: LocalizedStringResource = "Center ProMist"
    @Parameter(title: "Device") var device: ProMistDeviceEntity
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let control = await ProMistControlRegistry.shared.resolve()
        try await control.center(deviceID: device.deviceID)
        return .result(dialog: "Centered \(device.name).")
    }
}

struct SetProMistBreezeIntent: ProMistDeviceIntent {
    static let title: LocalizedStringResource = "Set ProMist Breeze"
    @Parameter(title: "Device") var device: ProMistDeviceEntity
    @Parameter(title: "Breeze") var breeze: ProMistBreeze
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let control = await ProMistControlRegistry.shared.resolve()
        try await control.setBreeze(deviceID: device.deviceID, mode: UInt8(breeze.rawValue))
        return .result(dialog: "Set \(device.name) breeze to \(String(describing: breeze)).")
    }
}

struct SetProMistOscillationWidthIntent: ProMistDeviceIntent {
    static let title: LocalizedStringResource = "Set ProMist Rotation"
    @Parameter(title: "Device") var device: ProMistDeviceEntity
    @Parameter(title: "Rotation") var width: ProMistOscillationWidth
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let control = await ProMistControlRegistry.shared.resolve()
        try await control.setOscillationWidth(deviceID: device.deviceID, mode: UInt8(width.rawValue))
        return .result(dialog: "Set \(device.name) rotation to \(width.spokenName).")
    }
}

struct FaceProMistIntent: ProMistDeviceIntent {
    static let title: LocalizedStringResource = "Point ProMist"
    @Parameter(title: "Device") var device: ProMistDeviceEntity
    @Parameter(title: "Direction") var direction: ProMistDirection

    init() {}

    init(direction: ProMistDirection) {
        self.direction = direction
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let control = await ProMistControlRegistry.shared.resolve()
        switch direction {
            case .forward:
                try await control.center(deviceID: device.deviceID)
            case .left:
                try await control.setPosition(deviceID: device.deviceID, position: 3)
            case .right:
                try await control.setPosition(deviceID: device.deviceID, position: -3)
        }
        return .result(dialog: "Pointed \(device.name) \(String(describing: direction)).")
    }
}

struct MoveProMistIntent: ProMistDeviceIntent {
    static let title: LocalizedStringResource = "Move ProMist"
    @Parameter(title: "Device") var device: ProMistDeviceEntity
    @Parameter(title: "Direction") var direction: ProMistJogDirection

    init() {}

    init(direction: ProMistJogDirection) {
        self.direction = direction
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let control = await ProMistControlRegistry.shared.resolve()
        // The fan's physical mapping is left = clockwise, right = counterclockwise.
        let jogValue: Int8 = direction == .left ? 1 : -1
        try await control.jog(deviceID: device.deviceID, direction: jogValue)
        return .result(dialog: "Moved \(device.name) \(String(describing: direction)).")
    }
}

struct ProMistAppShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: SetProMistOscillationWidthIntent(),
            phrases: [
                "Set \(.applicationName) rotation to \(\.$width)",
                "Set \(.applicationName) to \(\.$width) rotation",
                "Rotate \(.applicationName) \(\.$width)"
            ],
            shortTitle: "Set Rotation",
            systemImageName: "fan.oscillation"
        )
        AppShortcut(
            intent: FaceProMistIntent(),
            phrases: [
                "Point \(.applicationName)",
                "Face \(.applicationName)"
            ],
            shortTitle: "Point ProMist",
            systemImageName: "location.north"
        )
        AppShortcut(
            intent: FaceProMistIntent(direction: .left),
            phrases: [
                "Point \(.applicationName) left",
                "Point \(.applicationName) to the left",
                "Face \(.applicationName) left"
            ],
            shortTitle: "Point Left",
            systemImageName: "arrow.left"
        )
        AppShortcut(
            intent: FaceProMistIntent(direction: .right),
            phrases: [
                "Point \(.applicationName) right",
                "Point \(.applicationName) to the right",
                "Face \(.applicationName) right"
            ],
            shortTitle: "Point Right",
            systemImageName: "arrow.right"
        )
        AppShortcut(
            intent: FaceProMistIntent(direction: .forward),
            phrases: [
                "Point \(.applicationName) forward",
                "Point \(.applicationName) straight ahead",
                "Face \(.applicationName) forward"
            ],
            shortTitle: "Point Forward",
            systemImageName: "arrow.up"
        )
        AppShortcut(
            intent: MoveProMistIntent(),
            phrases: [
                "Move \(.applicationName)",
                "Nudge \(.applicationName)",
                "Jog \(.applicationName)"
            ],
            shortTitle: "Move ProMist",
            systemImageName: "arrow.left.and.right"
        )
        AppShortcut(
            intent: MoveProMistIntent(direction: .left),
            phrases: [
                "Move \(.applicationName) left",
                "Nudge \(.applicationName) left",
                "Jog \(.applicationName) left"
            ],
            shortTitle: "Nudge Left",
            systemImageName: "arrow.left"
        )
        AppShortcut(
            intent: MoveProMistIntent(direction: .right),
            phrases: [
                "Move \(.applicationName) right",
                "Nudge \(.applicationName) right",
                "Jog \(.applicationName) right"
            ],
            shortTitle: "Nudge Right",
            systemImageName: "arrow.right"
        )
        AppShortcut(
            intent: SetProMistMistIntent(),
            phrases: [
                "Set \(.applicationName) mist to \(\.$misting)",
                "Turn \(.applicationName) mist \(\.$misting)",
                "Misting \(\.$misting) with \(.applicationName)"
            ],
            shortTitle: "Set Misting",
            systemImageName: "humidity"
        )
    }

    static var shortcutTileColor: ShortcutTileColor { .blue }
}

struct PositionProMistIntent: ProMistDeviceIntent {
    static let title: LocalizedStringResource = "Position ProMist"
    @Parameter(title: "Device") var device: ProMistDeviceEntity
    @Parameter(title: "Position", inclusiveRange: (lowerBound: -3, upperBound: 3)) var position: Int
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let control = await ProMistControlRegistry.shared.resolve()
        try await control.setPosition(deviceID: device.deviceID, position: Int8(position))
        return .result(dialog: "Positioned \(device.name).")
    }
}
