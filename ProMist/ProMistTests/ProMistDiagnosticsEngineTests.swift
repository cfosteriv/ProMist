import XCTest
@testable import ProMist

@MainActor
final class ProMistDiagnosticsEngineTests: XCTestCase {
    func testPaginationDeduplicatesRecordsAndCompletes() {
        let transport = DiagnosticTestTransport()
        let engine = ProMistDiagnosticsEngine(transport: transport)
        transport.eventHandler = { [weak engine] in engine?.receive($0) }
        var result: ProMistDiagnosticsEngine.Completion?
        engine.finished = { result = $0 }

        engine.start(expectedCount: 2)
        let firstID = transport.lastRequestID
        transport.inject(record(sequence: 1, requestID: firstID))
        transport.inject(record(sequence: 1, requestID: firstID))
        transport.inject(completion(
            requestID: firstID, first: 1, last: 1, count: 1,
            next: 1, hasMore: true
        ))

        let secondID = transport.lastRequestID
        XCTAssertNotEqual(firstID, secondID)
        transport.inject(record(sequence: 2, requestID: secondID))
        transport.inject(completion(
            requestID: secondID, first: 2, last: 2, count: 1,
            next: 2, hasMore: false
        ))

        guard case .success(let records) = result else {
            return XCTFail("Expected completed diagnostics")
        }
        XCTAssertEqual(records.map(\.sequence), [1, 2])
    }

    func testDisconnectPreservesPartialRecordsInUpdatesButFailsCompletion() {
        let transport = DiagnosticTestTransport()
        let engine = ProMistDiagnosticsEngine(transport: transport)
        transport.eventHandler = { [weak engine] in engine?.receive($0) }
        var updates: [[ProMistDiagnostic]] = []
        var result: ProMistDiagnosticsEngine.Completion?
        engine.recordsChanged = { updates.append($0) }
        engine.finished = { result = $0 }

        engine.start(expectedCount: 2)
        let requestID = transport.lastRequestID
        transport.inject(record(sequence: 1, requestID: requestID))
        transport.inject(completion(
            requestID: requestID, first: 1, last: 1, count: 1,
            next: 1, hasMore: true
        ))
        transport.eventHandler?(.disconnected)

        XCTAssertEqual(updates.last?.map(\.sequence), [1])
        XCTAssertEqual(result, .failure(.disconnected))
    }

    private func record(sequence: UInt32, requestID: UInt32) -> Data {
        var diagnostic = sequence.littleEndianData + UInt32(100).littleEndianData
        diagnostic += UInt16(1).littleEndianData + Data([0, 0])
        diagnostic += Int32(0).littleEndianData + Int32(0).littleEndianData
        return Data([ProMistBLEProtocol.version, 1, 0, 0])
            + requestID.littleEndianData + diagnostic
    }

    private func completion(
        requestID: UInt32,
        first: UInt32,
        last: UInt32,
        count: UInt8,
        next: UInt32,
        hasMore: Bool
    ) -> Data {
        Data([ProMistBLEProtocol.version, 2, hasMore ? 1 : 0, 0])
            + requestID.littleEndianData
            + first.littleEndianData
            + last.littleEndianData
            + Data([count, 0, 0, 0])
            + next.littleEndianData
    }
}

@MainActor
private final class DiagnosticTestTransport: BLETransport {
    var eventHandler: ((BLETransportEvent) -> Void)?
    private(set) var sent: [Data] = []
    var lastRequestID: UInt32 { sent.last?.integer(at: 8) ?? 0 }

    func send(_ data: Data, to endpoint: BLETransportEndpoint) -> Bool {
        guard endpoint == .diagnosticRequest else { return false }
        sent.append(data)
        return true
    }

    func cancelOutstandingOperations() {}

    func inject(_ data: Data) {
        eventHandler?(.packet(endpoint: .diagnosticData, data: data))
    }
}
