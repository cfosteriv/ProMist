import Foundation
import Security

/// Owns enrollment and owner-authentication state. The engine has no
/// CoreBluetooth objects; it emits writes and terminal decisions for the
/// central transport owner to execute.
@MainActor
final class ProMistBLEAuthenticationEngine {
    struct Credentials {
        var load: (UInt64) -> Data?
        var save: (Data, UInt64) -> Bool
        var delete: (UInt64) throws -> Void

        @MainActor
        static var live: Credentials {
            Credentials(
                load: { OwnerCredentialStore.load(deviceID: $0) },
                save: { OwnerCredentialStore.save($0, deviceID: $1) },
                delete: { try OwnerCredentialStore.delete(deviceID: $0) }
            )
        }
    }

    enum Phase: Equatable, Sendable {
        case idle
        case authenticating(deviceID: UInt64)
        case authenticated(deviceID: UInt64)
    }

    enum TimeoutPhase: Equatable, Sendable {
        case authentication
        case capabilityResolution
    }

    enum Action: Equatable, Sendable {
        case writeSecurity(Data)
        case writeProvisioning(Data)
        case authenticationAccepted(deviceID: UInt64)
        case ownershipResetCompleted(deviceID: UInt64)
        case recoveryRequired(deviceID: UInt64)
        case timedOut(deviceID: UInt64, phase: TimeoutPhase)
        case failed(String)
        case trace(String)
    }

    private let credentials: Credentials
    private let nonceGenerator: () -> Data?
    private let timeout: Duration
    private var timeoutTask: Task<Void, Never>?
    private var clientNonce: Data?
    private var attemptedProvisioningAfterRejectedCredential = false
    private var pendingOwnershipResetDeviceID: UInt64?

    private(set) var phase: Phase = .idle
    var eventHandler: ((Action) -> Void)?

    init(
        credentials: Credentials,
        timeout: Duration = .seconds(10),
        nonceGenerator: @escaping () -> Data?
    ) {
        self.credentials = credentials
        self.timeout = timeout
        self.nonceGenerator = nonceGenerator
    }

    convenience init() {
        self.init(
            credentials: .live,
            timeout: .seconds(10),
            nonceGenerator: { ProMistBLEAuthenticationEngine.secureNonce() }
        )
    }

    var deviceID: UInt64? {
        switch phase {
        case .idle:
            nil
        case .authenticating(let deviceID), .authenticated(let deviceID):
            deviceID
        }
    }

    var isAuthenticated: Bool {
        if case .authenticated = phase { return true }
        return false
    }

    /// Returns whether a valid device-specific owner key is available locally.
    func hasCredential(for deviceID: UInt64) -> Bool {
        credentials.load(deviceID) != nil
    }

    /// Starts enrollment or saved-key authentication for a verified firmware
    /// identity and returns the transport writes the central must perform.
    func begin(deviceID: UInt64) -> [Action] {
        reset()
        phase = .authenticating(deviceID: deviceID)
        attemptedProvisioningAfterRejectedCredential = false
        armTimeout(for: deviceID)

        guard credentials.load(deviceID) != nil else {
            return [
                .writeProvisioning(ProMistBLEProtocol.provisionRequest()),
                .trace(
                    "Provisioning requested; awaiting physically-authorized device response"
                )
            ]
        }
        guard let nonce = nonceGenerator(), nonce.count == 32,
              let request = ProMistBLEProtocol.authenticationRequest(
                clientNonce: nonce
              ) else {
            return fail("A secure authentication challenge could not be started.")
        }
        clientNonce = nonce
        return [
            .writeSecurity(request),
            .trace("Authentication request sent device=\(deviceID)")
        ]
    }

    /// Advances the security exchange from one untrusted GATT notification.
    /// Malformed or out-of-order messages fail the active attempt.
    func receive(_ data: Data) -> [Action] {
        guard data.count >= 3,
              data[1] == ProMistBLEProtocol.version,
              let message = ProMistBLEProtocol.SecurityMessage(rawValue: data[0]),
              let deviceID
        else {
            return fail("The fan returned a malformed security response.")
        }

        if message == .provisioned, data.count == 34 {
            let ownerKey = Data(data.dropFirst(2))
            guard credentials.save(ownerKey, deviceID) else {
                return fail(
                    "The ownership credential could not be saved in Keychain."
                )
            }
            return acceptAuthentication(deviceID: deviceID)
        }

        if message == .authenticationChallenge, data.count == 34,
           let clientNonce,
           let ownerKey = credentials.load(deviceID),
           let response = ProMistBLEProtocol.authenticationResponse(
               ownerKey: ownerKey,
               deviceID: deviceID,
               clientNonce: clientNonce,
               deviceNonce: Data(data.dropFirst(2))
           ) {
            return [
                .writeSecurity(response),
                .trace("Authentication response sent")
            ]
        }

        if message == .authenticationResult, data.count == 3, data[2] == 0 {
            if let resetDeviceID = pendingOwnershipResetDeviceID {
                pendingOwnershipResetDeviceID = nil
                do {
                    try credentials.delete(resetDeviceID)
                    return [
                        .ownershipResetCompleted(deviceID: resetDeviceID),
                        .trace(
                            "Ownership reset confirmed device=\(resetDeviceID)"
                        )
                    ]
                } catch {
                    return [
                        .recoveryRequired(deviceID: resetDeviceID),
                        .failed(
                            "The fan reset ownership, but its local Keychain credential could not be deleted. Remove the fan again to retry: \(error.localizedDescription)"
                        )
                    ]
                }
            }
            return acceptAuthentication(deviceID: deviceID)
        }

        if message == .authenticationResult || data.count == 3 {
            let hasCredential = credentials.load(deviceID) != nil
            if hasCredential && !attemptedProvisioningAfterRejectedCredential {
                attemptedProvisioningAfterRejectedCredential = true
                clientNonce = nil
                return [
                    .writeProvisioning(ProMistBLEProtocol.provisionRequest()),
                    .trace(
                        "Saved credential rejected; requesting physical reprovision device=\(deviceID)"
                    )
                ]
            }
            var actions: [Action] = []
            if hasCredential {
                actions.append(.recoveryRequired(deviceID: deviceID))
            }
            actions.append(.failed(
                hasCredential
                ? "Owner authentication failed. Use the physical recovery gesture if this phone is no longer the owner."
                : "Hold the fan button for five seconds while the fan is off, then reconnect to provision it."
            ))
            phase = .idle
            cancelTimeout()
            return actions
        }

        return fail("The fan returned an unexpected security response.")
    }

    /// Encodes an ownership reset only for the currently authenticated device.
    func beginOwnershipReset(deviceID: UInt64) -> Data? {
        guard phase == .authenticated(deviceID: deviceID) else { return nil }
        pendingOwnershipResetDeviceID = deviceID
        return ProMistBLEProtocol.ownershipResetRequest()
    }

    func cancelOwnershipReset() {
        pendingOwnershipResetDeviceID = nil
    }

    /// Ends the session-readiness timeout after authentication and capability
    /// discovery have both succeeded.
    func capabilitiesResolved() {
        guard isAuthenticated else { return }
        cancelTimeout()
    }

    /// Clears connection-bound authentication and pending ownership state.
    func reset() {
        cancelTimeout()
        phase = .idle
        clientNonce = nil
        attemptedProvisioningAfterRejectedCredential = false
        pendingOwnershipResetDeviceID = nil
    }

    func transportRejected(_ action: Action) -> [Action] {
        switch action {
        case .writeProvisioning:
            fail("The fan does not expose the Phase 2 security service.")
        case .writeSecurity:
            fail("A secure authentication challenge could not be started.")
        case .authenticationAccepted, .ownershipResetCompleted,
             .recoveryRequired, .timedOut, .failed, .trace:
            []
        }
    }

    private func acceptAuthentication(deviceID: UInt64) -> [Action] {
        phase = .authenticated(deviceID: deviceID)
        clientNonce = nil
        return [.authenticationAccepted(deviceID: deviceID)]
    }

    private func fail(_ message: String) -> [Action] {
        phase = .idle
        clientNonce = nil
        cancelTimeout()
        return [.failed(message)]
    }

    private func armTimeout(for deviceID: UInt64) {
        cancelTimeout()
        timeoutTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: self?.timeout ?? .zero)
            guard !Task.isCancelled, let self else { return }
            let timeoutPhase: TimeoutPhase
            switch self.phase {
            case .authenticating(let activeDeviceID)
                where activeDeviceID == deviceID:
                timeoutPhase = .authentication
            case .authenticated(let activeDeviceID)
                where activeDeviceID == deviceID:
                timeoutPhase = .capabilityResolution
            case .idle, .authenticating, .authenticated:
                return
            }
            self.timeoutTask = nil
            self.eventHandler?(
                .timedOut(deviceID: deviceID, phase: timeoutPhase)
            )
        }
    }

    private func cancelTimeout() {
        timeoutTask?.cancel()
        timeoutTask = nil
    }

    private static func secureNonce() -> Data? {
        var nonce = Data(count: 32)
        let status = nonce.withUnsafeMutableBytes {
            SecRandomCopyBytes(kSecRandomDefault, 32, $0.baseAddress!)
        }
        return status == errSecSuccess ? nonce : nil
    }
}
