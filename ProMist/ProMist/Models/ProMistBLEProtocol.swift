// Canonical iOS representation of proprietary BLE v2. Packet builders remain
// pure so byte order, bounds, and authentication transcripts are unit-testable.
import Foundation
import CryptoKit
@preconcurrency import CoreBluetooth

enum ProMistBLEProtocol {
    static let version: UInt8 = 2
    static let service = CBUUID(string: "6F8A0001-7C5A-4D8F-9B21-8D12D9B00100")
    static let information = CBUUID(string: "6F8A0002-7C5A-4D8F-9B21-8D12D9B00100")
    static let security = CBUUID(string: "6F8A0003-7C5A-4D8F-9B21-8D12D9B00100")
    static let state = CBUUID(string: "6F8A0004-7C5A-4D8F-9B21-8D12D9B00100")
    static let command = CBUUID(string: "6F8A0005-7C5A-4D8F-9B21-8D12D9B00100")
    static let response = CBUUID(string: "6F8A0006-7C5A-4D8F-9B21-8D12D9B00100")
    static let logMetadata = CBUUID(string: "6F8A0007-7C5A-4D8F-9B21-8D12D9B00100")
    static let logRequest = CBUUID(string: "6F8A0008-7C5A-4D8F-9B21-8D12D9B00100")
    static let logData = CBUUID(string: "6F8A0009-7C5A-4D8F-9B21-8D12D9B00100")
    static let friendlyName = CBUUID(string: "6F8A000A-7C5A-4D8F-9B21-8D12D9B00100")
    static let matterOnboarding = CBUUID(string: "6F8A000B-7C5A-4D8F-9B21-8D12D9B00100")
    static let provisioning = CBUUID(string: "6F8A000C-7C5A-4D8F-9B21-8D12D9B00100")
    static let breezeSlot0 = CBUUID(string: "6F8A000D-7C5A-4D8F-9B21-8D12D9B00100")
    static let breezeSlot1 = CBUUID(string: "6F8A000E-7C5A-4D8F-9B21-8D12D9B00100")
    static let breezeSlot2 = CBUUID(string: "6F8A000F-7C5A-4D8F-9B21-8D12D9B00100")
    static let breezeSlots = [breezeSlot0, breezeSlot1, breezeSlot2]
    static let currentCharacteristics: Set<CBUUID> = [
        information, security, state, command, response,
        logMetadata, logRequest, logData, friendlyName,
        matterOnboarding, provisioning,
        breezeSlots[0], breezeSlots[1], breezeSlots[2]
    ]
    static let maximumFriendlyNameByteCount = 24

    enum Opcode: UInt8 {
        case power = 1
        case fanSpeed, mist, breeze, oscillation, direction
        case oscillationPosition
        case togglePower
        case timer
        case clearFaults
    }
    enum Result: UInt8 {
        case success, noChange, malformed, unsupportedVersion
        case unsupportedCommand, invalidValue, invalidTransition
        case duplicateRequest
        case unauthorized
    }

    enum SecurityMessage: UInt8 {
        case provisionRequest = 0x10, provisioned = 0x11
        case authenticationRequest = 0x20, authenticationChallenge = 0x21
        case authenticationResponse = 0x22, authenticationResult = 0x23
        case resetOwnership = 0x30
    }

    /// Encodes one fixed-width command packet.
    /// - Parameters:
    ///   - opcode: The operation the firmware should validate and apply.
    ///   - value: Signed wire value; meaning and valid range depend on `opcode`.
    ///   - requestID: Nonzero serial number used to correlate and deduplicate work.
    /// - Returns: An eight-byte, little-endian protocol-v2 packet.
    static func command(_ opcode: Opcode, value: Int8, requestID: UInt32) -> Data {
        Data([version, opcode.rawValue, 0, UInt8(bitPattern: value)]) + requestID.littleEndianData
    }

    /// Requests the next bounded diagnostic page after an exclusive cursor.
    /// - Parameters:
    ///   - sequence: Last sequence already consumed, or zero for the oldest page.
    ///   - limit: Requested record count; clamped to the firmware's 1...8 limit.
    static func logRequest(after sequence: UInt32, limit: UInt8 = 8, requestID: UInt32) -> Data {
        Data([version, min(max(limit, 1), 8), 0, 0])
            + sequence.littleEndianData + requestID.littleEndianData
    }

    enum LogFrame: Equatable {
        case record(requestID: UInt32, ProMistDiagnostic)
        case complete(requestID: UInt32, first: UInt32, last: UInt32,
                      count: UInt8, next: UInt32, hasMore: Bool)
    }

    static func logFrame(_ data: Data) -> LogFrame? {
        guard data.count >= 2, data[0] == version,
              let requestID: UInt32 = data.integer(at: 4), requestID != 0 else { return nil }
        if data[1] == 1, data.count == 28,
           let record = ProMistDiagnostic(data: Data(data[8..<28])) {
            return .record(requestID: requestID, record)
        }
        if data[1] == 2, data.count == 24, data[2] <= 1,
           let first: UInt32 = data.integer(at: 8),
           let last: UInt32 = data.integer(at: 12),
           let next: UInt32 = data.integer(at: 20) {
            return .complete(requestID: requestID, first: first, last: last,
                             count: data[16], next: next, hasMore: data[2] == 1)
        }
        return nil
    }

    static func provisionRequest() -> Data {
        Data([SecurityMessage.provisionRequest.rawValue, version])
    }

    static func ownershipResetRequest() -> Data {
        Data([SecurityMessage.resetOwnership.rawValue, version])
    }

    static func matterOnboardingRequest() -> Data { Data([version]) }

    static func matterOnboardingPayload(_ data: Data) -> String? {
        guard let payload = String(data: data, encoding: .ascii),
              payload.count == 11 || payload.count == 21,
              payload.allSatisfy(\.isNumber)
        else { return nil }
        return payload
    }

    static func authenticationRequest(clientNonce: Data) -> Data? {
        guard clientNonce.count == 32 else { return nil }
        return Data([SecurityMessage.authenticationRequest.rawValue, version]) + clientNonce
    }

    static func authenticationResponse(
        ownerKey: Data,
        deviceID: UInt64,
        clientNonce: Data,
        deviceNonce: Data
    ) -> Data? {
        guard ownerKey.count == 32, clientNonce.count == 32,
              deviceNonce.count == 32 else { return nil }
        let message = Data([version]) + deviceID.littleEndianData + clientNonce + deviceNonce
        let key = SymmetricKey(data: ownerKey)
        let tag = HMAC<SHA256>.authenticationCode(for: message, using: key)
        return Data([SecurityMessage.authenticationResponse.rawValue, version]) + Data(tag)
    }

    static func response(_ data: Data) -> (Result, Opcode, UInt32)? {
        guard data.count == 8, data[0] == version, data[3] == 0,
              let result = Result(rawValue: data[1]),
              let opcode = Opcode(rawValue: data[2]),
              let requestID: UInt32 = data.integer(at: 4), requestID != 0
        else { return nil }
        return (result, opcode, requestID)
    }

    static func friendlyName(_ name: String) -> Data? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let data = Data(trimmed.utf8)
        return data.count <= maximumFriendlyNameByteCount ? data : nil
    }

    static func identityMatches(expected: UInt64?, received: UInt64) -> Bool {
        received != 0 && (expected == nil || expected == received)
    }

    static func advertisementNameMatches(
        observedName: String,
        expectedName: String,
        deviceID: UInt64?
    ) -> Bool {
        if observedName.caseInsensitiveCompare(expectedName) == .orderedSame {
            return true
        }
        guard let deviceID else { return false }
        let shortenedName = String(
            format: "ProMist-%03llX",
            deviceID & 0xFFF
        )
        return observedName.caseInsensitiveCompare(shortenedName) == .orderedSame
    }
}

extension FixedWidthInteger {
    var littleEndianData: Data {
        var value = littleEndian
        return withUnsafeBytes(of: &value) { Data($0) }
    }
}

extension Data {
    func integer<T: FixedWidthInteger>(at offset: Int, as: T.Type = T.self) -> T? {
        guard offset >= 0, count >= offset + MemoryLayout<T>.size else { return nil }
        return withUnsafeBytes { raw in
            T(littleEndian: raw.loadUnaligned(fromByteOffset: offset, as: T.self))
        }
    }
}
