// Persistent, user-facing device identity and last-known state. Credentials are
// intentionally excluded so SwiftData exports cannot disclose owner secrets.
import Foundation
import SwiftData

@Model
final class KnownFan {
    /// Zero means this record was imported from Apple Home and has not yet
    /// been correlated with the proprietary BLE identity.
    var deviceID: UInt64
    var peripheralIdentifier: UUID?
    var name: String
    var lastConnectedAt: Date
    var lastPower: Bool = false
    var lastFanSpeed: UInt8 = 1
    var lastMistMode: UInt8 = 0
    var lastBreezeMode: UInt8 = 0
    var lastOscillationMode: UInt8 = 0
    var lastFault: UInt8 = 0
    /// Stable HomeKit identity. Names and rooms are deliberately not keys.
    var homeAccessoryIdentifier: UUID?
    var homeIdentifier: UUID?
    var matterNodeID: UInt64?
    var isMatterCommissioned: Bool = false

    var advertisedName: String {
        String(format: "ProMist-%06llX", deviceID & 0xFF_FFFF)
    }

    var isInAppleHome: Bool { homeAccessoryIdentifier != nil }
    var hasBLEIdentity: Bool { deviceID != 0 }
    var isHomeOnly: Bool { isInAppleHome && !hasBLEIdentity }

    init(
        deviceID: UInt64,
        peripheralIdentifier: UUID? = nil,
        name: String,
        lastConnectedAt: Date = .now,
        state: ProMistDeviceState = ProMistDeviceState()
    ) {
        self.deviceID = deviceID
        self.peripheralIdentifier = peripheralIdentifier
        self.name = name
        self.lastConnectedAt = lastConnectedAt
        lastPower = state.power
        lastFanSpeed = state.fanSpeed
        lastMistMode = state.mistMode
        lastBreezeMode = state.breezeMode
        lastOscillationMode = state.oscillationMode
        lastFault = state.fault
        isMatterCommissioned = state.matterCommissioning == .commissioned
    }

    func update(
        name: String,
        peripheralIdentifier: UUID?,
        state: ProMistDeviceState
    ) {
        self.name = name
        if let peripheralIdentifier {
            self.peripheralIdentifier = peripheralIdentifier
        }
        lastConnectedAt = .now
        lastPower = state.power
        lastFanSpeed = state.fanSpeed
        lastMistMode = state.mistMode
        lastBreezeMode = state.breezeMode
        lastOscillationMode = state.oscillationMode
        lastFault = state.fault
        isMatterCommissioned = state.matterCommissioning == .commissioned
    }
}
