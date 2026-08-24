// Pure session and response-correlation policy extracted from CoreBluetooth so
// reconnect, identity, timeout, and duplicate behavior can be tested directly.
import Foundation

/// Pure, deterministic state used by the CoreBluetooth delegate owner.
/// Keeping transport callbacks in `ProMistBLECentral` does not require session
/// policy and response correlation to live there as well.
struct ProMistBLESessionState {
    enum Phase: Equatable {
        case idle
        case connecting(expectedDeviceID: UInt64?)
        case authenticating(deviceID: UInt64)
        case authenticated(deviceID: UInt64)
        case ready(deviceID: UInt64)
        case failed
    }

    enum IdentityDecision: Equatable {
        case ignoreStale
        case waitForSecurity(deviceID: UInt64)
        case authenticate(deviceID: UInt64)
        case rejectMismatch
    }

    enum DisconnectDecision: Equatable {
        case reconnect
        case finish
    }

    private(set) var phase: Phase = .idle

    /// Starts identity verification for a selected or newly discovered fan.
    /// - Parameter expectedDeviceID: Saved full identity, or `nil` while enrolling.
    mutating func beginConnection(expectedDeviceID: UInt64?) {
        phase = .connecting(expectedDeviceID: expectedDeviceID)
    }

    /// Validates the firmware-reported identity before authentication begins.
    /// - Parameter deviceID: Full 64-bit value decoded from device information.
    /// - Returns: Whether to authenticate or reject a mismatched/zero identity.
    mutating func receiveIdentity(
        _ deviceID: UInt64,
        securityNotificationsReady: Bool = true
    ) -> IdentityDecision {
        guard case let .connecting(expectedDeviceID) = phase else {
            return .ignoreStale
        }
        guard deviceID != 0 else {
            phase = .failed
            return .rejectMismatch
        }
        guard expectedDeviceID == nil || expectedDeviceID == deviceID else {
            phase = .failed
            return .rejectMismatch
        }
        guard securityNotificationsReady else {
            return .waitForSecurity(deviceID: deviceID)
        }
        phase = .authenticating(deviceID: deviceID)
        return .authenticate(deviceID: deviceID)
    }

    @discardableResult
    mutating func authenticationSucceeded(deviceID: UInt64) -> Bool {
        guard phase == .authenticating(deviceID: deviceID) else { return false }
        phase = .authenticated(deviceID: deviceID)
        return true
    }

    @discardableResult
    mutating func capabilityResolutionSucceeded(deviceID: UInt64) -> Bool {
        guard phase == .authenticated(deviceID: deviceID) else { return false }
        phase = .ready(deviceID: deviceID)
        return true
    }

    @discardableResult
    mutating func authenticationFailed(deviceID: UInt64) -> Bool {
        guard phase == .authenticating(deviceID: deviceID) else { return false }
        phase = .failed
        return true
    }

    mutating func authenticationTimedOut(deviceID: UInt64) -> Bool {
        authenticationFailed(deviceID: deviceID)
    }

    mutating func connectionTimedOut() -> Bool {
        guard case .connecting = phase else { return false }
        phase = .failed
        return true
    }

    mutating func disconnect(reconnectRequested: Bool) -> DisconnectDecision {
        let wasReady: Bool
        if case .ready = phase { wasReady = true } else { wasReady = false }
        phase = .idle
        return wasReady && reconnectRequested ? .reconnect : .finish
    }

    mutating func fail() {
        phase = .failed
    }

    mutating func reset() {
        phase = .idle
    }
}

struct ProMistBLECommandTracker {
    private(set) var pendingRequestIDs = Set<UInt32>()

    mutating func begin(requestID: UInt32) -> Bool {
        pendingRequestIDs.insert(requestID).inserted
    }

    mutating func receiveResponse(requestID: UInt32) -> Bool {
        pendingRequestIDs.remove(requestID) != nil
    }

    mutating func timeout(requestID: UInt32) -> Bool {
        pendingRequestIDs.remove(requestID) != nil
    }

    mutating func disconnect() {
        pendingRequestIDs.removeAll()
    }
}

struct ProMistBLEDiagnosticPageAssembler {
    enum Completion: Equatable { case waiting, complete(next: UInt32, hasMore: Bool), invalid }
    let requestID: UInt32
    let afterSequence: UInt32
    private(set) var records: [UInt32: ProMistDiagnostic] = [:]
    private var completion: (first: UInt32, last: UInt32, count: UInt8, next: UInt32, hasMore: Bool)?

    init(requestID: UInt32, afterSequence: UInt32) {
        self.requestID = requestID
        self.afterSequence = afterSequence
    }

    mutating func receive(_ frame: ProMistBLEProtocol.LogFrame) -> Completion {
        switch frame {
        case let .record(id, record):
            guard id == requestID, record.sequence > afterSequence else { return .waiting }
            records[record.sequence] = record
        case let .complete(id, first, last, count, next, hasMore):
            guard id == requestID else { return .waiting }
            if completion == nil { completion = (first, last, count, next, hasMore) }
        }
        return status
    }

    var status: Completion {
        guard let completion else { return .waiting }
        let ordered = records.keys.sorted()
        guard ordered.count == Int(completion.count) else { return .waiting }
        if ordered.isEmpty {
            return completion.first == 0 && completion.last == afterSequence
                ? .complete(next: completion.next, hasMore: completion.hasMore) : .invalid
        }
        guard ordered.first == completion.first, ordered.last == completion.last,
              completion.next == completion.last else { return .invalid }
        for pair in zip(ordered, ordered.dropFirst()) where pair.1 != pair.0 &+ 1 { return .invalid }
        return .complete(next: completion.next, hasMore: completion.hasMore)
    }

    var orderedRecords: [ProMistDiagnostic] { records.values.sorted { $0.sequence < $1.sequence } }
}

/// Independent one-write/one-ack custom breeze transfer policy. Packet/CRC
/// validation stays in the wire codec; this state owns correlation and the
/// follow-up slot-selection decision.
struct ProMistBreezeTransferState {
    enum Acknowledgment: Equatable {
        case ignored
        case completedWithoutSelection
        case select(mode: UInt8)
    }

    private var pending: (slot: Int, presetID: UInt32)?

    mutating func begin(slot: Int, presetID: UInt32) {
        pending = (slot, presetID)
    }

    mutating func receive(slot: Int, presetID: UInt32?) -> Acknowledgment {
        guard let pending, pending.slot == slot else { return .ignored }
        self.pending = nil
        guard presetID == pending.presetID else {
            return .completedWithoutSelection
        }
        return .select(mode: UInt8(4 + slot))
    }

    mutating func cancel() { pending = nil }
}
