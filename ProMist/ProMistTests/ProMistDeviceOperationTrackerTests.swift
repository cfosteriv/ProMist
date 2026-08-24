import XCTest
@testable import ProMist

@MainActor
final class ProMistDeviceOperationTrackerTests: XCTestCase {
    func testReplacingOperationFinishesOldTokenAndKeepsOneActive() {
        let tracker = ProMistDeviceOperationTracker(timeout: .seconds(30))
        var events: [ProMistDeviceOperationTracker.Event] = []
        tracker.eventHandler = { events.append($0) }

        let first = tracker.begin(
            .stateRefresh,
            label: "state refresh",
            replacingExisting: true
        )
        let second = tracker.begin(
            .stateRefresh,
            label: "state refresh",
            replacingExisting: true
        )

        XCTAssertNotEqual(first, second)
        XCTAssertEqual(tracker.activeCount, 1)
        XCTAssertTrue(tracker.isActive(.stateRefresh))
        XCTAssertTrue(events.contains(.finished(
            token: first,
            kind: .stateRefresh,
            reason: "superseded state refresh",
            activeCount: 0
        )))
    }

    func testFinishingByKindIsIdempotent() {
        let tracker = ProMistDeviceOperationTracker(timeout: .seconds(30))
        tracker.begin(.command(requestID: 7), label: "command 7")

        XCTAssertTrue(tracker.finish(
            .command(requestID: 7),
            reason: "command response"
        ))
        XCTAssertFalse(tracker.finish(
            .command(requestID: 7),
            reason: "duplicate response"
        ))
        XCTAssertEqual(tracker.activeCount, 0)
    }

    func testTimeoutOwnsLifecycleCleanup() async {
        let tracker = ProMistDeviceOperationTracker(timeout: .milliseconds(10))
        var events: [ProMistDeviceOperationTracker.Event] = []
        tracker.eventHandler = { events.append($0) }
        tracker.begin(.friendlyName, label: "friendly name")

        try? await Task.sleep(for: .milliseconds(40))

        XCTAssertEqual(tracker.activeCount, 0)
        XCTAssertTrue(events.contains { event in
            if case .finished(_, .friendlyName, "timeout", 0) = event {
                return true
            }
            return false
        })
    }

    func testClearCancelsAllKinds() {
        let tracker = ProMistDeviceOperationTracker(timeout: .seconds(30))
        tracker.begin(.command(requestID: 1), label: "command 1")
        tracker.begin(.diagnostics, label: "diagnostics refresh")

        tracker.clear(reason: "disconnect")

        XCTAssertEqual(tracker.activeCount, 0)
        XCTAssertFalse(tracker.isActive(.command(requestID: 1)))
        XCTAssertFalse(tracker.isActive(.diagnostics))
    }
}
