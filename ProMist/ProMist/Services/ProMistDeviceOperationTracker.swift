import Foundation

/// Owns the lifecycle of user-visible device I/O independently of the BLE
/// transport. Operations are keyed by their semantic purpose so a replacement
/// cannot leave stale activity or timeout bookkeeping behind.
@MainActor
final class ProMistDeviceOperationTracker {
    enum Kind: Hashable, Sendable {
        case command(requestID: UInt32)
        case stateRefresh
        case friendlyName
        case diagnostics
    }

    struct Token: Hashable, Sendable {
        let rawValue: UInt64
    }

    enum Event: Equatable, Sendable {
        case started(token: Token, kind: Kind, label: String, activeCount: Int)
        case finished(
            token: Token,
            kind: Kind,
            reason: String,
            activeCount: Int
        )
        case cleared(reason: String)
    }

    private struct Operation {
        let token: Token
        let kind: Kind
        let label: String
        let timeoutTask: Task<Void, Never>
    }

    private let timeout: Duration
    private var nextTokenValue: UInt64 = 0
    private var operations: [Token: Operation] = [:]
    private var tokensByKind: [Kind: Token] = [:]

    var eventHandler: ((Event) -> Void)?

    init(timeout: Duration = .seconds(8)) {
        self.timeout = timeout
    }

    var activeCount: Int { operations.count }

    func isActive(_ kind: Kind) -> Bool {
        tokensByKind[kind] != nil
    }

    /// Begins a semantic operation and schedules its automatic timeout.
    ///
    /// - Parameter replacingExisting: When `true`, finishes an operation with
    ///   the same kind before installing the new token.
    @discardableResult
    func begin(
        _ kind: Kind,
        label: String,
        replacingExisting: Bool = false
    ) -> Token {
        if replacingExisting {
            finish(kind, reason: "superseded \(label)")
        }

        nextTokenValue &+= 1
        if nextTokenValue == 0 { nextTokenValue = 1 }
        let token = Token(rawValue: nextTokenValue)
        let timeoutTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: self?.timeout ?? .zero)
            guard !Task.isCancelled, let self else { return }
            self.finish(token, reason: "timeout")
        }
        operations[token] = Operation(
            token: token,
            kind: kind,
            label: label,
            timeoutTask: timeoutTask
        )
        tokensByKind[kind] = token
        eventHandler?(
            .started(
                token: token,
                kind: kind,
                label: label,
                activeCount: activeCount
            )
        )
        return token
    }

    /// Finishes the active operation of a given semantic kind, if present.
    @discardableResult
    func finish(_ kind: Kind, reason: String) -> Bool {
        guard let token = tokensByKind[kind] else { return false }
        return finish(token, reason: reason)
    }

    @discardableResult
    func finish(_ token: Token, reason: String) -> Bool {
        guard let operation = operations.removeValue(forKey: token) else {
            return false
        }
        operation.timeoutTask.cancel()
        if tokensByKind[operation.kind] == token {
            tokensByKind.removeValue(forKey: operation.kind)
        }
        eventHandler?(
            .finished(
                token: token,
                kind: operation.kind,
                reason: reason,
                activeCount: activeCount
            )
        )
        return true
    }

    /// Cancels all timeout tasks during disconnect or session teardown.
    func clear(reason: String) {
        operations.values.forEach { $0.timeoutTask.cancel() }
        operations.removeAll()
        tokensByKind.removeAll()
        eventHandler?(.cleared(reason: reason))
    }
}
