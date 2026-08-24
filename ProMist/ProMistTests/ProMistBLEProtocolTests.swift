// Cross-language wire-contract tests. These cases reject malformed input and
// pin byte order/HMAC behavior independently of CoreBluetooth hardware.
import XCTest
import Security
@testable import ProMist

@MainActor
final class ProMistBLEProtocolTests: XCTestCase {
    func testCommandEncodingIsVersionedAndLittleEndian() {
        // Canonical fixture: 0203000178563412
        XCTAssertEqual(
            ProMistBLEProtocol.command(.mist, value: 1, requestID: 0x12345678),
            Data([2, 3, 0, 1, 0x78, 0x56, 0x34, 0x12])
        )
    }

    func testTogglePowerCommandEncoding() {
        XCTAssertEqual(
            ProMistBLEProtocol.command(
                .togglePower,
                value: 0,
                requestID: 0x12345678
            ),
            Data([2, 8, 0, 0, 0x78, 0x56, 0x34, 0x12])
        )
    }

    func testTimerCommandEncoding() {
        XCTAssertEqual(
            ProMistBLEProtocol.command(.timer, value: 45, requestID: 7),
            Data([2, 9, 0, 45, 7, 0, 0, 0])
        )
    }

    func testClearFaultCommandEncoding() {
        XCTAssertEqual(
            ProMistBLEProtocol.command(.clearFaults, value: 0, requestID: 10),
            Data([2, 10, 0, 0, 10, 0, 0, 0])
        )
    }

    func testStateDecoding() {
        var data = Data([2, 3, 5, 1, 2, 3, 0xFF, 0])
        data += UInt32(42).littleEndianData
        data += UInt32(90).littleEndianData
        data += UInt64(0x1122334455667788).littleEndianData
        data += UInt32(899).littleEndianData
        data += UInt32(900).littleEndianData
        let state = ProMistDeviceState(data: data)
        XCTAssertEqual(state?.power, true)
        XCTAssertEqual(state?.fanConfirmed, true)
        XCTAssertEqual(state?.fanSpeed, 5)
        XCTAssertEqual(state?.oscillationPosition, -1)
        XCTAssertEqual(state?.revision, 42)
        XCTAssertEqual(state?.deviceID, 0x1122334455667788)
        XCTAssertEqual(state?.timerRemainingSeconds, 899)
        XCTAssertEqual(state?.timerDurationSeconds, 900)
    }

    func testSessionSnapshotExpiresAfterThirtyMinutes() {
        let observedAt = Date(timeIntervalSinceReferenceDate: 1_000)
        let snapshot = ProMistSessionSnapshot(
            state: ProMistDeviceState(),
            observedAt: observedAt
        )
        XCTAssertTrue(snapshot.isFresh(at: observedAt.addingTimeInterval(1_799)))
        XCTAssertTrue(snapshot.isFresh(at: observedAt.addingTimeInterval(1_800)))
        XCTAssertFalse(snapshot.isFresh(at: observedAt.addingTimeInterval(1_801)))
        XCTAssertFalse(snapshot.isFresh(at: observedAt.addingTimeInterval(-1)))
    }

    func testMalformedStateIsRejected() {
        XCTAssertNil(ProMistDeviceState(data: Data(repeating: 0, count: 23)))
    }

    func testImpossibleStateValuesAreRejected() {
        var base = Data([2, 1, 5, 1, 2, 3, 0, 0])
        base += UInt32(1).littleEndianData + UInt32(1).littleEndianData
        base += UInt64(1).littleEndianData
        for (offset, value) in [(2, UInt8(6)), (3, 2), (4, 7), (5, 4), (6, 4)] {
            var invalid = base
            invalid[offset] = value
            XCTAssertNil(ProMistDeviceState(data: invalid))
        }
        var oldVersion = base
        oldVersion[0] = 1
        XCTAssertNil(ProMistDeviceState(data: oldVersion))
    }

    func testResponseValidation() {
        // Canonical fixture: 0208030078563412
        let valid = Data([2, 8, 3, 0, 0x78, 0x56, 0x34, 0x12])
        XCTAssertEqual(ProMistBLEProtocol.response(valid)?.0, .unauthorized)
        XCTAssertEqual(ProMistBLEProtocol.response(valid)?.2, 0x12345678)
        XCTAssertNil(ProMistBLEProtocol.response(Data(valid.dropLast())))
    }

    func testFriendlyNameUtf8Boundary() {
        XCTAssertEqual(ProMistBLEProtocol.friendlyName(String(repeating: "é", count: 12))?.count, 24)
        XCTAssertNil(ProMistBLEProtocol.friendlyName(String(repeating: "é", count: 13)))
        XCTAssertNil(ProMistBLEProtocol.friendlyName("   "))
    }

    func testMatterOnboardingPayloadValidation() {
        XCTAssertEqual(ProMistBLEProtocol.matterOnboardingRequest(), Data([2]))
        XCTAssertEqual(
            ProMistBLEProtocol.matterOnboardingPayload(Data("34970112332".utf8)),
            "34970112332"
        )
        XCTAssertNil(ProMistBLEProtocol.matterOnboardingPayload(Data("34970A12332".utf8)))
        XCTAssertNil(ProMistBLEProtocol.matterOnboardingPayload(Data("1234".utf8)))
    }

    func testKnownDeviceIdentityMismatch() {
        XCTAssertTrue(ProMistBLEProtocol.identityMatches(expected: 42, received: 42))
        XCTAssertFalse(ProMistBLEProtocol.identityMatches(expected: 42, received: 43))
        XCTAssertFalse(ProMistBLEProtocol.identityMatches(expected: nil, received: 0))
    }

    func testKnownDeviceMatchesFullAndMatterShortAdvertisementNames() {
        let deviceID: UInt64 = 0x08B61FB9F2E0
        XCTAssertTrue(ProMistBLEProtocol.advertisementNameMatches(
            observedName: "ProMist-B9F2E0",
            expectedName: "ProMist-B9F2E0",
            deviceID: deviceID
        ))
        XCTAssertTrue(ProMistBLEProtocol.advertisementNameMatches(
            observedName: "ProMist-2E0",
            expectedName: "ProMist-B9F2E0",
            deviceID: deviceID
        ))
        XCTAssertFalse(ProMistBLEProtocol.advertisementNameMatches(
            observedName: "ProMist-2E1",
            expectedName: "ProMist-B9F2E0",
            deviceID: deviceID
        ))
    }

    func testAuthenticationFixture() {
        let key = Data((0..<32).map(UInt8.init))
        let client = Data((0..<32).map(UInt8.init))
        let device = Data((32..<64).map(UInt8.init))
        let response = ProMistBLEProtocol.authenticationResponse(
            ownerKey: key, deviceID: 0x0102030405060708,
            clientNonce: client, deviceNonce: device
        )
        XCTAssertEqual(
            response?.dropFirst(2).hex,
            "74898e0484ec7baef027fe9e759eba0e9a7e490f85bb85950a7585759005f357"
        )
    }

    func testDiagnosticDecoding() {
        var data = UInt32(7).littleEndianData
        data += UInt32(1500).littleEndianData
        data += UInt16(301).littleEndianData
        data += Data([3, 4])
        data += Int32(-2).littleEndianData
        data += Int32(9).littleEndianData
        let record = ProMistDiagnostic(data: data)
        XCTAssertEqual(record?.sequence, 7)
        XCTAssertEqual(record?.eventID, 301)
        XCTAssertEqual(record?.first, -2)
    }

    func testFramedDiagnosticRequestAndCompletion() {
        XCTAssertEqual(ProMistBLEProtocol.logRequest(after: 9, requestID: 44),
                       Data([2, 8, 0, 0, 9, 0, 0, 0, 44, 0, 0, 0]))
        var complete = Data([2, 2, 0, 0]) + UInt32(44).littleEndianData
        complete += UInt32(0).littleEndianData + UInt32(9).littleEndianData
        complete += Data([0, 0, 0, 0]) + UInt32(9).littleEndianData
        XCTAssertEqual(ProMistBLEProtocol.logFrame(complete),
                       .complete(requestID: 44, first: 0, last: 9,
                                 count: 0, next: 9, hasMore: false))
    }

    func testKeychainUpdateIsTransactionalAndDeviceOnly() {
        let fake = FakeKeychainClient()
        fake.updateStatus = errSecSuccess
        OwnerCredentialStore.client = fake
        XCTAssertTrue(OwnerCredentialStore.save(Data(repeating: 7, count: 32), deviceID: 42))
        XCTAssertEqual(fake.deleteCalls, 0)
        XCTAssertEqual(fake.addCalls, 0)
        XCTAssertEqual(fake.updatedAttributes?[kSecAttrAccessible as String] as? String,
                       kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String)

        fake.updateStatus = errSecItemNotFound
        XCTAssertTrue(OwnerCredentialStore.save(Data(repeating: 8, count: 32), deviceID: 42))
        XCTAssertEqual(fake.addCalls, 1)
        XCTAssertEqual(fake.addedQuery?[kSecAttrService as String] as? String,
                       "com.demo.ProMist.owner")
        XCTAssertEqual(fake.addedQuery?[kSecAttrAccount as String] as? String, "42")
    }

    func testKeychainFailuresPreserveExistingCredential() {
        let fake = FakeKeychainClient()
        fake.updateStatus = errSecInteractionNotAllowed
        OwnerCredentialStore.client = fake
        XCTAssertFalse(OwnerCredentialStore.save(Data(repeating: 1, count: 32), deviceID: 1))
        XCTAssertEqual(fake.deleteCalls, 0)
        XCTAssertEqual(fake.addCalls, 0)
        fake.copyStatus = errSecSuccess
        fake.copyResult = Data(repeating: 2, count: 31) as CFData
        XCTAssertNil(OwnerCredentialStore.load(deviceID: 1))
        fake.deleteStatus = errSecItemNotFound
        fake.copyStatus = errSecItemNotFound
        XCTAssertNoThrow(try OwnerCredentialStore.delete(deviceID: 1))
    }

    func testCredentialDeletionVerifiesSuccessfulAbsence() throws {
        let fake = FakeKeychainClient()
        fake.deleteStatus = errSecSuccess
        fake.copyStatus = errSecItemNotFound
        OwnerCredentialStore.client = fake

        try OwnerCredentialStore.delete(deviceID: 42)

        XCTAssertEqual(fake.deleteCalls, 1)
        XCTAssertEqual(fake.copyCalls, 1)
    }

    func testCredentialDeletionFailurePreservesPersistentRecordAndRetrySucceeds() {
        let fake = FakeKeychainClient()
        fake.deleteStatus = errSecInteractionNotAllowed
        OwnerCredentialStore.client = fake
        var recordExists = true

        XCTAssertThrowsError(try LocalDeviceRemovalCoordinator.remove(
            securityDeletionRequired: true,
            deleteCredential: { try OwnerCredentialStore.delete(deviceID: 42) },
            deletePersistentRecord: { recordExists = false }
        ))
        XCTAssertTrue(recordExists)

        fake.deleteStatus = errSecSuccess
        fake.copyStatus = errSecItemNotFound
        XCTAssertNoThrow(try LocalDeviceRemovalCoordinator.remove(
            securityDeletionRequired: true,
            deleteCredential: { try OwnerCredentialStore.delete(deviceID: 42) },
            deletePersistentRecord: { recordExists = false }
        ))
        XCTAssertFalse(recordExists)
    }

    func testDeletionRejectsCredentialThatStillExistsAfterKeychainSuccess() {
        let fake = FakeKeychainClient()
        fake.deleteStatus = errSecSuccess
        fake.copyStatus = errSecSuccess
        fake.copyResult = Data(repeating: 1, count: 32) as CFData
        OwnerCredentialStore.client = fake

        XCTAssertThrowsError(try OwnerCredentialStore.delete(deviceID: 42)) {
            XCTAssertEqual($0 as? OwnerCredentialDeletionError, .verificationFailed)
        }
    }

    func testResetAllReportsEveryDeletionFailureAndIsIdempotentOnRetry() {
        let fake = FakeKeychainClient()
        fake.deleteStatus = errSecInteractionNotAllowed
        OwnerCredentialStore.client = fake

        XCTAssertThrowsError(try OwnerCredentialStore.deleteAll(deviceIDs: [1, 2]))
        XCTAssertEqual(fake.deleteCalls, 2)

        fake.deleteStatus = errSecItemNotFound
        fake.copyStatus = errSecItemNotFound
        XCTAssertNoThrow(try OwnerCredentialStore.deleteAll(deviceIDs: [1, 2]))
        XCTAssertEqual(fake.deleteCalls, 4)
    }
}

private final class FakeKeychainClient: KeychainClient {
    var copyStatus: OSStatus = errSecItemNotFound
    var copyResult: CFTypeRef?
    var updateStatus: OSStatus = errSecItemNotFound
    var addStatus: OSStatus = errSecSuccess
    var deleteStatus: OSStatus = errSecSuccess
    var addCalls = 0
    var deleteCalls = 0
    var copyCalls = 0
    var updatedAttributes: [String: Any]?
    var addedQuery: [String: Any]?
    func copyMatching(_ query: CFDictionary) -> (OSStatus, CFTypeRef?) {
        copyCalls += 1
        return (copyStatus, copyResult)
    }
    func update(_ query: CFDictionary, attributes: CFDictionary) -> OSStatus {
        updatedAttributes = attributes as? [String: Any]; return updateStatus
    }
    func add(_ query: CFDictionary) -> OSStatus {
        addCalls += 1; addedQuery = query as? [String: Any]; return addStatus
    }
    func delete(_ query: CFDictionary) -> OSStatus { deleteCalls += 1; return deleteStatus }
}

private extension DataProtocol {
    var hex: String { map { String(format: "%02x", $0) }.joined() }
}
