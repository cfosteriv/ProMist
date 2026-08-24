// Transport-neutral command contract used by App Intents. The registry bridges
// system-created intent instances to the app-owned Bluetooth coordinator.
import Foundation

enum ProMistControlError: LocalizedError, CustomLocalizedStringResourceConvertible,
    Equatable, Sendable {
    case bluetoothUnavailable, deviceNotFound, authenticationUnavailable
    case timedOut, rejected, bluetoothHandoffTimedOut, matterSetupUnavailable

    var errorDescription: String? {
        switch self {
        case .bluetoothUnavailable: "Bluetooth is unavailable."
        case .deviceNotFound: "ProMist is not nearby."
        case .authenticationUnavailable: "ProMist could not be authenticated."
        case .timedOut: "ProMist did not confirm the command in time."
        case .rejected: "ProMist could not perform that action right now."
        case .bluetoothHandoffTimedOut:
            "ProMist could not release its Bluetooth connection for Apple Home. Try again."
        case .matterSetupUnavailable:
            "ProMist could not provide its Matter setup information. Update the fan firmware and try again."
        }
    }

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .bluetoothUnavailable:
            "Bluetooth is turned off or unavailable."
        case .deviceNotFound:
            "I couldn't find the ProMist fan nearby."
        case .authenticationUnavailable:
            "ProMist couldn't authenticate this iPhone. Open the app and reconnect the fan."
        case .timedOut:
            "ProMist didn't respond in time. Please try again."
        case .rejected:
            "ProMist can't perform that action in its current state."
        case .bluetoothHandoffTimedOut:
            "ProMist couldn't release its Bluetooth connection for Apple Home."
        case .matterSetupUnavailable:
            "ProMist couldn't provide its Matter setup information."
        }
    }
}

protocol ProMistControlling: Sendable {
    /// - Parameters:
    ///   - deviceID: Full firmware identity of the intended fan.
    ///   - enabled: Requested binary mister output; this is not proof of water flow.
    func setMist(deviceID: UInt64, enabled: Bool) async throws
    /// - Parameters:
    ///   - deviceID: Full firmware identity of the intended fan.
    ///   - mode: Firmware breeze mode in the inclusive range 0...3.
    func setBreeze(deviceID: UInt64, mode: UInt8) async throws
    /// - Parameters:
    ///   - deviceID: Full firmware identity of the intended fan.
    ///   - mode: Oscillation width where 0 is off and 1...3 are increasing arcs.
    func setOscillationWidth(deviceID: UInt64, mode: UInt8) async throws
    /// - Parameters:
    ///   - deviceID: Full firmware identity of the intended fan.
    ///   - position: Fixed preset in the inclusive range -3...3.
    func setPosition(deviceID: UInt64, position: Int8) async throws
    /// - Parameters:
    ///   - deviceID: Full firmware identity of the intended fan.
    ///   - direction: `-1` counter-clockwise or `1` clockwise.
    func jog(deviceID: UInt64, direction: Int8) async throws
    /// Homes the oscillation assembly for the identified fan.
    func center(deviceID: UInt64) async throws
}

/// Intents depend on this transport-neutral boundary. The foreground app can
/// install a BLE implementation; a future IP transport can implement it too.
actor ProMistControlRegistry {
    static let shared = ProMistControlRegistry()
    private var controller: (any ProMistControlling)?
    func install(_ controller: any ProMistControlling) { self.controller = controller }
    func resolve() async -> any ProMistControlling {
        if let controller { return controller }
        let controller = await MainActor.run {
            ProMistBLECentral.shared.deviceSessionCoordinator
        }
        self.controller = controller
        return controller
    }
}
