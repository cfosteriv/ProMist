import Foundation

enum ProMistBLETransactionError: LocalizedError, Equatable {
    case transportUnavailable
    case malformedResponse
    case unexpectedOpcode(expected: UInt8, received: UInt8)
    case timedOut
    case cancelled
    case disconnected

    var errorDescription: String? {
        switch self {
        case .transportUnavailable: "The Bluetooth command could not be sent."
        case .malformedResponse: "The fan returned a malformed command response."
        case let .unexpectedOpcode(expected, received):
            "The fan returned opcode \(received) for a request expecting \(expected)."
        case .timedOut: "The Bluetooth command timed out."
        case .cancelled: "The Bluetooth command was cancelled."
        case .disconnected: "The fan disconnected before the command completed."
        }
    }
}

/// Typed proprietary command/response transaction engine. All mutable state is
/// main-actor isolated with the CoreBluetooth coordinator that owns its transport.
@MainActor
final class ProMistBLECommandEngine {
    typealias Outcome = Result<ProMistBLEProtocol.Result, ProMistBLETransactionError>

    var transactionStarted: ((UInt32) -> Void)?
    var transactionFinished: ((UInt32, Outcome) -> Void)?

    private struct Pending {
        let opcode: ProMistBLEProtocol.Opcode
        let cancellationID: UUID?
        var continuation: CheckedContinuation<ProMistBLEProtocol.Result, Error>?
        let timeout: Task<Void, Never>
    }

    private let transport: any BLETransport
    private let timeout: Duration
    private var nextRequestID: UInt32 = 0
    private var pending: [UInt32: Pending] = [:]

    init(transport: any BLETransport, timeout: Duration = .seconds(4)) {
        self.transport = transport
        self.timeout = timeout
    }

    var pendingRequestIDs: Set<UInt32> { Set(pending.keys) }

    /// Starts a callback-observed command transaction.
    ///
    /// - Returns: The allocated nonzero request ID, or `nil` when the transport
    ///   rejects the write synchronously.
    @discardableResult
    func submit(_ opcode: ProMistBLEProtocol.Opcode, value: Int8) -> UInt32? {
        start(opcode, value: value, cancellationID: nil, continuation: nil)
    }

    /// Sends a command and waits for the response carrying its request ID.
    ///
    /// - Throws: A transport, timeout, cancellation, disconnect, or response
    ///   validation error. Firmware-level command rejection is returned as a
    ///   ``ProMistBLEProtocol/Result``.
    func execute(
        _ opcode: ProMistBLEProtocol.Opcode,
        value: Int8
    ) async throws -> ProMistBLEProtocol.Result {
        let cancellationID = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(throwing: ProMistBLETransactionError.cancelled)
                    return
                }
                // `start` installs the continuation before attempting the
                // transport write. From that point onward `finish` is the
                // sole completion owner, including synchronous send failure.
                // Resuming here as well would double-resume the checked
                // continuation when `transport.send` returns false.
                _ = start(
                    opcode,
                    value: value,
                    cancellationID: cancellationID,
                    continuation: continuation
                )
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancel(cancellationID: cancellationID) }
        }
    }

    /// Consumes response and link events from the current BLE session.
    func receive(_ event: BLETransportEvent) {
        switch event {
        case let .packet(.commandResponse, data):
            receiveResponse(data)
        case .disconnected:
            failAll(.disconnected)
        case .reconnected:
            // A new link never revives transactions from a previous link.
            break
        case .packet:
            break
        }
    }

    /// Cancels every pending continuation and outstanding transport operation.
    func cancelAll() {
        transport.cancelOutstandingOperations()
        failAll(.cancelled)
    }

    /// Restarts request allocation after authentication creates a new firmware
    /// session. An active transaction prevents the reset.
    func resetRequestSequence() {
        guard pending.isEmpty else { return }
        nextRequestID = 0
    }

    private func start(
        _ opcode: ProMistBLEProtocol.Opcode,
        value: Int8,
        cancellationID: UUID?,
        continuation: CheckedContinuation<ProMistBLEProtocol.Result, Error>?
    ) -> UInt32? {
        let requestID = allocateRequestID()
        let timeout = Task { @MainActor [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: self.timeout)
            guard !Task.isCancelled else { return }
            self.finish(requestID, outcome: .failure(.timedOut))
        }
        pending[requestID] = Pending(
            opcode: opcode,
            cancellationID: cancellationID,
            continuation: continuation,
            timeout: timeout
        )
        transactionStarted?(requestID)
        guard transport.send(
            ProMistBLEProtocol.command(opcode, value: value, requestID: requestID),
            to: .command
        ) else {
            finish(requestID, outcome: .failure(.transportUnavailable))
            return nil
        }
        return requestID
    }

    private func allocateRequestID() -> UInt32 {
        repeat {
            nextRequestID &+= 1
            if nextRequestID == 0 { nextRequestID = 1 }
        } while pending[nextRequestID] != nil
        return nextRequestID
    }

    private func receiveResponse(_ data: Data) {
        // Recover the request ID from a fixed-size response even when version,
        // result, or opcode validation fails, so the affected request fails
        // deterministically instead of waiting for a generic timeout.
        guard data.count == 8, let requestID: UInt32 = data.integer(at: 4),
              requestID != 0, let transaction = pending[requestID]
        else { return }
        guard let (result, opcode, _) = ProMistBLEProtocol.response(data) else {
            finish(requestID, outcome: .failure(.malformedResponse))
            return
        }
        guard opcode == transaction.opcode else {
            finish(
                requestID,
                outcome: .failure(.unexpectedOpcode(
                    expected: transaction.opcode.rawValue,
                    received: opcode.rawValue
                ))
            )
            return
        }
        finish(requestID, outcome: .success(result))
    }

    private func cancel(cancellationID: UUID) {
        guard let requestID = pending.first(where: {
            $0.value.cancellationID == cancellationID
        })?.key
        else { return }
        finish(requestID, outcome: .failure(.cancelled))
    }

    private func failAll(_ error: ProMistBLETransactionError) {
        for requestID in Array(pending.keys) {
            finish(requestID, outcome: .failure(error))
        }
    }

    private func finish(_ requestID: UInt32, outcome: Outcome) {
        guard let transaction = pending.removeValue(forKey: requestID) else {
            return // duplicate or late response
        }
        transaction.timeout.cancel()
        if let continuation = transaction.continuation {
            switch outcome {
            case .success(let result): continuation.resume(returning: result)
            case .failure(let error): continuation.resume(throwing: error)
            }
        }
        transactionFinished?(requestID, outcome)
    }
}
