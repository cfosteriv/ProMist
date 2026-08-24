import Foundation

/// Logical protocol endpoints used by orchestration code. CoreBluetooth UUIDs
/// intentionally remain in the coordinator's production transport closure.
enum BLETransportEndpoint: Equatable, Sendable {
    case command
    case commandResponse
    case diagnosticRequest
    case diagnosticData
}

/// Events a protocol engine can receive without importing CoreBluetooth.
enum BLETransportEvent: Equatable, Sendable {
    case packet(endpoint: BLETransportEndpoint, data: Data)
    case disconnected
    case reconnected
}

/// Deliberately narrow boundary between protocol workflows and CoreBluetooth.
/// It is not a general Bluetooth abstraction.
@MainActor
protocol BLETransport: AnyObject {
    var eventHandler: ((BLETransportEvent) -> Void)? { get set }
    /// Writes one packet to a logical endpoint.
    ///
    /// - Returns: `true` when the transport accepted the write for delivery.
    @discardableResult
    func send(_ data: Data, to endpoint: BLETransportEndpoint) -> Bool
    /// Cancels transport work that must not survive a session teardown.
    func cancelOutstandingOperations()
}

/// Production adapter. `ProMistBLECentral` supplies the UUID-aware writer and
/// forwards delegate events into `receive(_:)`, retaining sole delegate ownership.
@MainActor
final class CoreBluetoothBLETransport: BLETransport {
    var eventHandler: ((BLETransportEvent) -> Void)?

    private let writer: (Data, BLETransportEndpoint) -> Bool
    private let cancellation: () -> Void

    /// Creates an adapter around coordinator-owned GATT write and cancellation
    /// closures. Both closures execute on the main actor.
    init(
        writer: @escaping (Data, BLETransportEndpoint) -> Bool,
        cancellation: @escaping () -> Void = {}
    ) {
        self.writer = writer
        self.cancellation = cancellation
    }

    @discardableResult
    func send(_ data: Data, to endpoint: BLETransportEndpoint) -> Bool {
        writer(data, endpoint)
    }

    func cancelOutstandingOperations() {
        cancellation()
    }

    /// Forwards a coordinator delegate event to the active protocol engine.
    func receive(_ event: BLETransportEvent) {
        eventHandler?(event)
    }
}
