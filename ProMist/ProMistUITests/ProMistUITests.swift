import XCTest

@MainActor
final class ProMistUITests: XCTestCase {
    func testAppLaunchesIntoDeterministicDisconnectedState() {
        let app = launch()

        XCTAssertTrue(element("promist-root", in: app).waitForExistence(timeout: 5))
        XCTAssertTrue(element("initial-device-setup", in: app).exists)
        XCTAssertTrue(app.buttons["Connect"].exists)
    }

    func testFullProfileShowsCurrentCapabilityGroups() {
        let app = launch(profile: "full")

        XCTAssertTrue(element("fan-controls", in: app).waitForExistence(timeout: 5))
        XCTAssertTrue(element("mist-controls", in: app).exists)
        XCTAssertTrue(element("oscillation-controls", in: app).exists)
        XCTAssertTrue(element("oscillation-position-controls", in: app).exists)

        app.buttons["device-settings-button"].tap()
        XCTAssertTrue(element("diagnostics-controls", in: app).waitForExistence(timeout: 5))
    }

    func testNoMistProfileKeepsFanAndHidesMist() {
        let app = launch(profile: "noMist")

        XCTAssertTrue(element("fan-controls", in: app).waitForExistence(timeout: 5))
        XCTAssertFalse(element("mist-controls", in: app).exists)
    }

    func testBasicOscillationProfileHidesPositioning() {
        let app = launch(profile: "basicOscillationOnly")

        XCTAssertTrue(element("oscillation-controls", in: app).waitForExistence(timeout: 5))
        XCTAssertFalse(element("oscillation-position-controls", in: app).exists)
    }

    func testNoDiagnosticsProfileHidesDiagnostics() {
        let app = launch(profile: "noDiagnostics")
        XCTAssertTrue(
            app.buttons["device-settings-button"].waitForExistence(timeout: 5)
        )

        app.buttons["device-settings-button"].tap()
        XCTAssertTrue(app.navigationBars["Device Settings"].waitForExistence(timeout: 5))
        XCTAssertFalse(element("diagnostics-controls", in: app).exists)
    }

    private func launch(profile: String? = nil) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-ProMistUITestMode"]
        if let profile {
            app.launchArguments += ["-ProMistCapabilities", profile]
        }
        app.launch()
        return app
    }

    private func element(
        _ identifier: String,
        in app: XCUIApplication
    ) -> XCUIElement {
        app.descendants(matching: .any)[identifier]
    }
}
