// Validated value models decoded from untrusted BLE bytes. Failable initializers
// keep impossible wire values out of observable application state.
import Foundation

struct ProMistDeviceState: Equatable, Sendable {
    enum MatterCommissioning: UInt8, Sendable {
        case notConfigured, commissionable, commissioned
    }
    var power = false
    var fanConfirmed = false
    var fanSpeed: UInt8 = 1
    var mistMode: UInt8 = 0
    var breezeMode: UInt8 = 0
    var oscillationMode: UInt8 = 0
    var oscillationPosition: Int8 = -128
    var oscillationPositioning = false
    var oscillationTargetPosition: Int8 = -128
    var fault: UInt8 = 0
    var revision: UInt32 = 0
    var uptimeSeconds: UInt32 = 0
    var deviceID: UInt64 = 0
    var matterCommissioning: MatterCommissioning = .notConfigured
    var timerRemainingSeconds: UInt32 = 0
    var timerDurationSeconds: UInt32 = 0

    init() {}

    /// Decodes a protocol-v2 state snapshot.
    /// - Parameter data: The current 32-byte value, or its original 24-byte
    ///   prefix. Accepting the prefix lets the app reconnect while firmware is
    ///   updated; current firmware always publishes the timer-capable value.
    /// - Important: Returns `nil` for wrong versions, sizes, identities, or ranges.
    init?(data: Data) {
        guard (data.count == 24 || data.count == 32),
              data[0] == ProMistBLEProtocol.version,
              let revision: UInt32 = data.integer(at: 8),
              let uptime: UInt32 = data.integer(at: 12),
              let deviceID: UInt64 = data.integer(at: 16) else { return nil }
        let flags = data[1]
        guard let matterState = MatterCommissioning(rawValue: flags >> 6),
              (1...5).contains(data[2]), data[3] <= 1,
              data[4] <= 6, data[5] <= 3, data[7] <= 6,
              deviceID != 0 else { return nil }
        let position = Int8(bitPattern: data[6])
        guard position == -128 || (-3...3).contains(position) else { return nil }
        power = data[1] & 0x01 != 0
        fanConfirmed = data[1] & 0x02 != 0
        fanSpeed = data[2]
        mistMode = data[3]
        breezeMode = data[4]
        oscillationMode = data[5]
        oscillationPosition = position
        oscillationPositioning = data[1] & 0x04 != 0
        if oscillationPositioning {
            let encodedTarget = Int8((data[1] >> 3) & 0x07)
            oscillationTargetPosition = encodedTarget <= 6
                ? encodedTarget - 3
                : -128
            guard oscillationTargetPosition != -128 else { return nil }
        }
        fault = data[7]
        self.revision = revision
        uptimeSeconds = uptime
        self.deviceID = deviceID
        matterCommissioning = matterState
        if data.count == 32 {
            guard let remaining: UInt32 = data.integer(at: 24),
                  let duration: UInt32 = data.integer(at: 28),
                  remaining <= duration,
                  duration == 0 || [900, 1_800, 2_700, 3_600].contains(duration)
            else { return nil }
            timerRemainingSeconds = remaining
            timerDurationSeconds = duration
        }
    }
}

struct ProMistSessionSnapshot: Equatable, Sendable {
    static let maximumAge: TimeInterval = 30 * 60

    let state: ProMistDeviceState
    let observedAt: Date

    func isFresh(at date: Date = .now) -> Bool {
        let age = date.timeIntervalSince(observedAt)
        return age >= 0 && age <= Self.maximumAge
    }
}

struct ProMistDiagnostic: Identifiable, Equatable, Sendable {
    let sequence: UInt32
    let uptimeMilliseconds: UInt32
    let eventID: UInt16
    let severity: UInt8
    let component: UInt8
    let first: Int32
    let second: Int32
    var id: UInt32 { sequence }

    init?(data: Data) {
        guard data.count == 20,
              let sequence: UInt32 = data.integer(at: 0),
              let uptime: UInt32 = data.integer(at: 4),
              let eventID: UInt16 = data.integer(at: 8),
              let first: Int32 = data.integer(at: 12),
              let second: Int32 = data.integer(at: 16) else { return nil }
        self.sequence = sequence
        uptimeMilliseconds = uptime
        self.eventID = eventID
        severity = data[10]
        component = data[11]
        self.first = first
        self.second = second
    }
}

enum ProMistConnectionState: Equatable {
    case bluetoothUnavailable, idle, scanning, connecting, discovering, ready, failed(String)
}
