import XCTest
@testable import ProMist

@MainActor
final class ProMistMatterCommissioningCoordinatorTests: XCTestCase {
    func testOnboardingRequestCompletesFromValidatedPayload() async throws {
        var requests = 0
        let coordinator = makeCoordinator(request: {
            requests += 1
            return true
        })
        let pending = Task {
            try await coordinator.requestOnboardingPayload(available: true)
        }
        await Task.yield()

        coordinator.receiveOnboardingData(Data("34970112332".utf8))

        let payload = try await pending.value
        XCTAssertEqual(payload, "34970112332")
        XCTAssertEqual(requests, 1)
    }

    func testMalformedPayloadAndTimeoutFailDeterministically() async {
        let malformed = makeCoordinator()
        let malformedRequest = Task {
            try await malformed.requestOnboardingPayload(available: true)
        }
        await Task.yield()
        malformed.receiveOnboardingData(Data("not-a-payload".utf8))
        await assertMatterUnavailable(malformedRequest)

        let timeout = makeCoordinator(requestTimeout: .milliseconds(10))
        let timedRequest = Task {
            try await timeout.requestOnboardingPayload(available: true)
        }
        await assertMatterUnavailable(timedRequest)
    }

    func testHandoffOwnsDisconnectWaitAndPublishedLifecycle() async throws {
        var disconnected = false
        var handoffStates: [Bool] = []
        let coordinator = makeCoordinator(
            disconnect: { disconnected = true },
            isDisconnected: { disconnected },
            handoff: { handoffStates.append($0) }
        )

        try await coordinator.releaseTransportForCommissioning(
            deviceID: 42,
            authorized: true
        )

        XCTAssertTrue(coordinator.isHandoffActive)
        XCTAssertEqual(handoffStates, [true])
        coordinator.finishHandoff()
        XCTAssertFalse(coordinator.isHandoffActive)
        XCTAssertEqual(handoffStates, [true, false])
    }

    func testUnauthorizedAndDisconnectTimeoutRemainExplicit() async {
        let coordinator = makeCoordinator(isDisconnected: { false })
        do {
            try await coordinator.releaseTransportForCommissioning(
                deviceID: 42,
                authorized: false
            )
            XCTFail("Expected authentication failure")
        } catch {
            XCTAssertEqual(error as? ProMistControlError, .authenticationUnavailable)
        }

        do {
            try await coordinator.releaseTransportForCommissioning(
                deviceID: 42,
                authorized: true
            )
            XCTFail("Expected handoff timeout")
        } catch {
            XCTAssertEqual(error as? ProMistControlError, .bluetoothHandoffTimedOut)
        }
    }

    private func makeCoordinator(
        request: @escaping () -> Bool = { true },
        disconnect: @escaping () -> Void = {},
        isDisconnected: @escaping () -> Bool = { true },
        handoff: @escaping (Bool) -> Void = { _ in },
        requestTimeout: Duration = .seconds(1)
    ) -> ProMistMatterCommissioningCoordinator {
        ProMistMatterCommissioningCoordinator(
            dependencies: .init(
                requestOnboardingPayload: request,
                disconnectProprietarySession: disconnect,
                isTransportDisconnected: isDisconnected,
                handoffStateChanged: handoff,
                trace: { _ in }
            ),
            requestTimeout: requestTimeout,
            disconnectPollInterval: .milliseconds(1),
            disconnectPollLimit: 2,
            advertisementSettleDelay: .milliseconds(1)
        )
    }

    private func assertMatterUnavailable(
        _ task: Task<String, Error>
    ) async {
        do {
            _ = try await task.value
            XCTFail("Expected Matter setup failure")
        } catch {
            XCTAssertEqual(error as? ProMistControlError, .matterSetupUnavailable)
        }
    }
}
