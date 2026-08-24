import Foundation

enum ProMistDiagnosticsError: LocalizedError, Equatable {
    case transportUnavailable
    case malformedPage
    case incompletePage
    case cancelled
    case disconnected

    var errorDescription: String? {
        switch self {
        case .transportUnavailable: "The diagnostic request could not be sent."
        case .malformedPage: "The fan returned malformed diagnostic data."
        case .incompletePage: "The fan did not complete diagnostic pagination."
        case .cancelled: "Diagnostic refresh was cancelled."
        case .disconnected: "The fan disconnected during diagnostic pagination."
        }
    }
}

/// Owns diagnostic pagination and retry state without owning CoreBluetooth.
@MainActor
final class ProMistDiagnosticsEngine {
    typealias Completion = Result<[ProMistDiagnostic], ProMistDiagnosticsError>

    var recordsChanged: (([ProMistDiagnostic]) -> Void)?
    var finished: ((Completion) -> Void)?

    private let transport: any BLETransport
    private let timeout: Duration
    private let retryLimit: Int
    private var nextRequestID: UInt32 = 0
    private var expectedCount = 0
    private var cursor: UInt32 = 0
    private var retryCount = 0
    private var page: ProMistBLEDiagnosticPageAssembler?
    private var records: [UInt32: ProMistDiagnostic] = [:]
    private var timeoutTask: Task<Void, Never>?
    private(set) var isActive = false

    init(
        transport: any BLETransport,
        timeout: Duration = .seconds(3),
        retryLimit: Int = 2
    ) {
        self.transport = transport
        self.timeout = timeout
        self.retryLimit = retryLimit
    }

    /// Replaces any active refresh and pages from sequence zero until the
    /// advertised record count has been assembled.
    ///
    /// - Parameter expectedCount: Record count from the authenticated metadata
    ///   characteristic.
    func start(expectedCount: Int) {
        cancel(notify: false)
        self.expectedCount = expectedCount
        records.removeAll()
        cursor = 0
        retryCount = 0
        isActive = true
        recordsChanged?([])
        if expectedCount == 0 {
            complete(.success([]))
        } else {
            requestPage(after: 0)
        }
    }

    /// Accepts diagnostic frames and session disconnect events. Other protocol
    /// endpoint packets are ignored.
    func receive(_ event: BLETransportEvent) {
        switch event {
        case let .packet(.diagnosticData, data):
            guard isActive else { return }
            guard let frame = ProMistBLEProtocol.logFrame(data) else {
                retry(or: .malformedPage)
                return
            }
            receive(frame)
        case .disconnected where isActive:
            complete(.failure(.disconnected))
        case .packet, .disconnected, .reconnected:
            break
        }
    }

    /// Stops pagination and reports cancellation through `finished`.
    func cancel() { cancel(notify: true) }

    private func receive(_ frame: ProMistBLEProtocol.LogFrame) {
        guard var page else { return }
        let status = page.receive(frame)
        self.page = page
        switch status {
        case .waiting:
            break
        case .invalid:
            retry(or: .malformedPage)
        case let .complete(next, hasMore):
            timeoutTask?.cancel()
            for record in page.orderedRecords { records[record.sequence] = record }
            let ordered = records.values.sorted { $0.sequence < $1.sequence }
            recordsChanged?(ordered)
            if hasMore {
                retryCount = 0
                requestPage(after: next)
            } else if ordered.count == expectedCount {
                complete(.success(ordered))
            } else {
                retry(or: .incompletePage)
            }
        }
    }

    private func requestPage(after sequence: UInt32) {
        cursor = sequence
        nextRequestID &+= 1
        if nextRequestID == 0 { nextRequestID = 1 }
        let requestID = nextRequestID
        page = ProMistBLEDiagnosticPageAssembler(
            requestID: requestID,
            afterSequence: sequence
        )
        guard transport.send(
            ProMistBLEProtocol.logRequest(after: sequence, requestID: requestID),
            to: .diagnosticRequest
        ) else {
            complete(.failure(.transportUnavailable))
            return
        }
        timeoutTask?.cancel()
        timeoutTask = Task { @MainActor [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: self.timeout)
            guard !Task.isCancelled else { return }
            self.retry(or: .incompletePage)
        }
    }

    private func retry(or error: ProMistDiagnosticsError) {
        guard isActive, retryCount < retryLimit else {
            complete(.failure(error))
            return
        }
        retryCount += 1
        requestPage(after: cursor)
    }

    private func cancel(notify: Bool) {
        guard isActive else { return }
        if notify { complete(.failure(.cancelled)) }
        else { reset() }
    }

    private func complete(_ result: Completion) {
        guard isActive else { return }
        reset()
        finished?(result)
    }

    private func reset() {
        timeoutTask?.cancel()
        timeoutTask = nil
        page = nil
        isActive = false
        retryCount = 0
        expectedCount = 0
    }
}
