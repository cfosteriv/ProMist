import XCTest
@testable import ProMist

@MainActor
final class ProMistBLECommandEngineTests: XCTestCase {
    func testOverlappingOutOfOrderAndDuplicateResponses() async throws {
        let transport = DeterministicBLETransport()
        let engine = ProMistBLECommandEngine(transport: transport)
        transport.eventHandler = { [weak engine] in engine?.receive($0) }

        let first = engine.submit(.power, value: 1)
        let second = engine.submit(.mist, value: 1)
        XCTAssertEqual(first, 1)
        XCTAssertEqual(second, 2)
        XCTAssertEqual(engine.pendingRequestIDs, [1, 2])

        transport.inject(response(.success, opcode: .mist, requestID: 2))
        transport.inject(response(.success, opcode: .mist, requestID: 2))
        XCTAssertEqual(engine.pendingRequestIDs, [1])

        transport.inject(response(.noChange, opcode: .power, requestID: 1))
        XCTAssertTrue(engine.pendingRequestIDs.isEmpty)
    }

    func testMalformedAndWrongOpcodeFailOnlyCorrelatedTransaction() {
        let transport = DeterministicBLETransport()
        let engine = ProMistBLECommandEngine(transport: transport)
        transport.eventHandler = { [weak engine] in engine?.receive($0) }
        var outcomes: [UInt32: ProMistBLECommandEngine.Outcome] = [:]
        engine.transactionFinished = { outcomes[$0] = $1 }

        _ = engine.submit(.power, value: 1)
        _ = engine.submit(.mist, value: 1)
        var malformed = response(.success, opcode: .power, requestID: 1)
        malformed[0] = 0xFF
        transport.inject(malformed)
        transport.inject(response(.success, opcode: .fanSpeed, requestID: 2))

        XCTAssertEqual(outcomes[1], .failure(.malformedResponse))
        XCTAssertEqual(
            outcomes[2],
            .failure(.unexpectedOpcode(
                expected: ProMistBLEProtocol.Opcode.mist.rawValue,
                received: ProMistBLEProtocol.Opcode.fanSpeed.rawValue
            ))
        )
    }

    func testDisconnectFailsPendingAndReconnectDoesNotReviveIt() {
        let transport = DeterministicBLETransport()
        let engine = ProMistBLECommandEngine(transport: transport)
        transport.eventHandler = { [weak engine] in engine?.receive($0) }
        var outcomes: [ProMistBLECommandEngine.Outcome] = []
        engine.transactionFinished = { _, outcome in outcomes.append(outcome) }

        _ = engine.submit(.power, value: 1)
        _ = engine.submit(.mist, value: 1)
        transport.disconnect()
        transport.reconnect()
        transport.inject(response(.success, opcode: .power, requestID: 1))

        XCTAssertEqual(outcomes, [.failure(.disconnected), .failure(.disconnected)])
        XCTAssertTrue(engine.pendingRequestIDs.isEmpty)
    }

    func testDroppedResponseTimesOutAndLateResponseIsIgnored() async {
        let transport = DeterministicBLETransport()
        let engine = ProMistBLECommandEngine(
            transport: transport,
            timeout: .milliseconds(20)
        )
        transport.eventHandler = { [weak engine] in engine?.receive($0) }
        var outcomes: [ProMistBLECommandEngine.Outcome] = []
        engine.transactionFinished = { _, outcome in outcomes.append(outcome) }

        _ = engine.submit(.power, value: 1)
        try? await Task.sleep(for: .milliseconds(40))
        transport.inject(response(.success, opcode: .power, requestID: 1))

        XCTAssertEqual(outcomes, [.failure(.timedOut)])
    }

    func testTypedExecutionReturnsCorrelatedResult() async throws {
        let transport = DeterministicBLETransport()
        let engine = ProMistBLECommandEngine(transport: transport)
        transport.eventHandler = { [weak engine] in engine?.receive($0) }

        let task = Task { @MainActor in
            try await engine.execute(.clearFaults, value: 0)
        }
        await Task.yield()
        transport.inject(
            response(.noChange, opcode: .clearFaults, requestID: 1),
            delay: .milliseconds(5)
        )
        let result = try await task.value
        XCTAssertEqual(result, .noChange)
    }

    func testSendFailureCompletesExactlyOnceAndLeavesNoPendingTransaction() async {
        let transport = DeterministicBLETransport(sendResults: [false])
        let engine = ProMistBLECommandEngine(transport: transport)
        var completions: [ProMistBLECommandEngine.Outcome] = []
        engine.transactionFinished = { _, outcome in completions.append(outcome) }

        do {
            _ = try await engine.execute(.power, value: 1)
            XCTFail("Expected transportUnavailable")
        } catch let error as ProMistBLETransactionError {
            XCTAssertEqual(error, .transportUnavailable)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        XCTAssertEqual(completions, [.failure(.transportUnavailable)])
        XCTAssertTrue(engine.pendingRequestIDs.isEmpty)

        // Neither a late response nor a disconnect may complete the failed
        // transaction a second time.
        transport.inject(response(.success, opcode: .power, requestID: 1))
        transport.disconnect()
        XCTAssertEqual(completions, [.failure(.transportUnavailable)])
    }

    func testSuccessfulTransactionAfterSendFailure() async throws {
        let transport = DeterministicBLETransport(sendResults: [false, true])
        let engine = ProMistBLECommandEngine(transport: transport)
        transport.eventHandler = { [weak engine] in engine?.receive($0) }

        do {
            _ = try await engine.execute(.power, value: 1)
            XCTFail("Expected transportUnavailable")
        } catch let error as ProMistBLETransactionError {
            XCTAssertEqual(error, .transportUnavailable)
        }

        let success = Task { @MainActor in
            try await engine.execute(.mist, value: 1)
        }
        await Task.yield()
        XCTAssertEqual(engine.pendingRequestIDs, [2])
        transport.inject(response(.success, opcode: .mist, requestID: 2))

        let successfulResponse = try await success.value
        XCTAssertEqual(successfulResponse, .success)
        XCTAssertTrue(engine.pendingRequestIDs.isEmpty)
    }

    func testSendFailureDoesNotDisturbAnotherPendingTransaction() async throws {
        let transport = DeterministicBLETransport(sendResults: [true, false])
        let engine = ProMistBLECommandEngine(transport: transport)
        transport.eventHandler = { [weak engine] in engine?.receive($0) }
        var completionCount: [UInt32: Int] = [:]
        engine.transactionFinished = { requestID, _ in
            completionCount[requestID, default: 0] += 1
        }

        XCTAssertEqual(engine.submit(.power, value: 1), 1)
        do {
            _ = try await engine.execute(.mist, value: 1)
            XCTFail("Expected transportUnavailable")
        } catch let error as ProMistBLETransactionError {
            XCTAssertEqual(error, .transportUnavailable)
        }

        XCTAssertEqual(engine.pendingRequestIDs, [1])
        XCTAssertEqual(completionCount[2], 1)
        transport.inject(response(.noChange, opcode: .power, requestID: 1))
        XCTAssertTrue(engine.pendingRequestIDs.isEmpty)
        XCTAssertEqual(completionCount, [1: 1, 2: 1])
    }

    private func response(
        _ result: ProMistBLEProtocol.Result,
        opcode: ProMistBLEProtocol.Opcode,
        requestID: UInt32
    ) -> Data {
        Data([ProMistBLEProtocol.version, result.rawValue, opcode.rawValue, 0])
            + requestID.littleEndianData
    }
}

/// Deterministic transport used by orchestration tests. Tests can inject
/// delay, duplication, reordering, malformed packets, drops, and link changes.
@MainActor
private final class DeterministicBLETransport: BLETransport {
    var eventHandler: ((BLETransportEvent) -> Void)?
    private(set) var sent: [(Data, BLETransportEndpoint)] = []
    private var sendResults: [Bool]

    init(sendResults: [Bool] = []) {
        self.sendResults = sendResults
    }

    func send(_ data: Data, to endpoint: BLETransportEndpoint) -> Bool {
        sent.append((data, endpoint))
        return sendResults.isEmpty ? true : sendResults.removeFirst()
    }

    func cancelOutstandingOperations() {}

    func inject(_ data: Data, delay: Duration = .zero) {
        guard delay != .zero else {
            eventHandler?(.packet(endpoint: .commandResponse, data: data))
            return
        }
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: delay)
            self?.eventHandler?(.packet(endpoint: .commandResponse, data: data))
        }
    }

    func disconnect() { eventHandler?(.disconnected) }
    func reconnect() { eventHandler?(.reconnected) }
}
