import Foundation

/// Owns the asynchronous Matter onboarding request and the deliberate release
/// of the proprietary BLE session before Apple begins commissioning. The
/// central remains responsible for the actual characteristic write and link.
@MainActor
final class ProMistMatterCommissioningCoordinator {
    struct Dependencies {
        var requestOnboardingPayload: () -> Bool
        var disconnectProprietarySession: () -> Void
        var isTransportDisconnected: () -> Bool
        var handoffStateChanged: (Bool) -> Void
        var trace: (String) -> Void
    }

    private let dependencies: Dependencies
    private let requestTimeout: Duration
    private let disconnectPollInterval: Duration
    private let disconnectPollLimit: Int
    private let advertisementSettleDelay: Duration
    private var onboardingContinuation: CheckedContinuation<String, Error>?
    private var onboardingTimeoutTask: Task<Void, Never>?

    private(set) var isHandoffActive = false

    init(
        dependencies: Dependencies,
        requestTimeout: Duration = .seconds(3),
        disconnectPollInterval: Duration = .milliseconds(100),
        disconnectPollLimit: Int = 40,
        advertisementSettleDelay: Duration = .milliseconds(750)
    ) {
        self.dependencies = dependencies
        self.requestTimeout = requestTimeout
        self.disconnectPollInterval = disconnectPollInterval
        self.disconnectPollLimit = disconnectPollLimit
        self.advertisementSettleDelay = advertisementSettleDelay
    }

    /// Requests the authenticated, device-specific setup payload and waits for
    /// the matching characteristic notification.
    func requestOnboardingPayload(available: Bool) async throws -> String {
        guard available else { throw ProMistControlError.matterSetupUnavailable }
        cancelOnboardingRequest()
        return try await withCheckedThrowingContinuation { continuation in
            onboardingContinuation = continuation
            onboardingTimeoutTask = Task { @MainActor [weak self] in
                guard let self else { return }
                try? await Task.sleep(for: self.requestTimeout)
                guard !Task.isCancelled else { return }
                self.finishOnboardingRequest(
                    .failure(ProMistControlError.matterSetupUnavailable)
                )
            }
            guard dependencies.requestOnboardingPayload() else {
                finishOnboardingRequest(
                    .failure(ProMistControlError.matterSetupUnavailable)
                )
                return
            }
            dependencies.trace("Requested authenticated Matter onboarding payload")
        }
    }

    /// Completes the pending payload request from untrusted GATT bytes.
    func receiveOnboardingData(_ data: Data) {
        guard onboardingContinuation != nil else { return }
        guard let payload = ProMistBLEProtocol.matterOnboardingPayload(data) else {
            dependencies.trace("Matter onboarding payload rejected: malformed")
            finishOnboardingRequest(
                .failure(ProMistControlError.matterSetupUnavailable)
            )
            return
        }
        dependencies.trace("Authenticated Matter onboarding payload received")
        finishOnboardingRequest(.success(payload))
    }

    /// Disconnects the proprietary session and waits for the shared radio to
    /// settle before Apple's commissioner begins BLE work.
    func releaseTransportForCommissioning(
        deviceID: UInt64,
        authorized: Bool
    ) async throws {
        guard authorized else {
            throw ProMistControlError.authenticationUnavailable
        }
        setHandoffActive(true)
        dependencies.trace(
            "Releasing custom BLE link for Matter commissioning device=\(deviceID)"
        )
        dependencies.disconnectProprietarySession()
        for _ in 0..<disconnectPollLimit {
            if dependencies.isTransportDisconnected() {
                try await Task.sleep(for: advertisementSettleDelay)
                dependencies.trace(
                    "Custom BLE link released for Matter commissioning"
                )
                return
            }
            try await Task.sleep(for: disconnectPollInterval)
        }
        throw ProMistControlError.bluetoothHandoffTimedOut
    }

    func finishHandoff() {
        guard isHandoffActive else { return }
        setHandoffActive(false)
        dependencies.trace("Matter commissioning handoff finished")
    }

    func cancelOnboardingRequest() {
        finishOnboardingRequest(
            .failure(ProMistControlError.matterSetupUnavailable)
        )
    }

    func reset() {
        cancelOnboardingRequest()
        setHandoffActive(false)
    }

    private func setHandoffActive(_ active: Bool) {
        guard isHandoffActive != active else { return }
        isHandoffActive = active
        dependencies.handoffStateChanged(active)
    }

    private func finishOnboardingRequest(_ result: Result<String, Error>) {
        guard let continuation = onboardingContinuation else { return }
        onboardingContinuation = nil
        onboardingTimeoutTask?.cancel()
        onboardingTimeoutTask = nil
        continuation.resume(with: result)
    }
}
