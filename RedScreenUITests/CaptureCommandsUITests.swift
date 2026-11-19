import XCTest

/// Capture commands, region-selection cancellation, permission guidance, and shortcut settings,
/// driven against the Debug build's injected fakes. No real screen content is captured.
final class CaptureCommandsUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
    }

    override func tearDownWithError() throws {
        app.terminate()
    }

    private func launch(permission: String, extra: [String] = []) {
        app.launchArguments = ["-RedScreenUITestPermission", permission, "-RedScreenUITestFakeCapture", "YES",
                               "-RedScreenUITestFakeShortcuts", "YES"] + extra
        app.launch()
    }

    @MainActor
    func testMenuCommandCapturesDisplayIntoDocument() {
        launch(permission: "granted")
        chooseFromPopoverCaptureMenu("capture-display-button")

        let image = app.descendants(matching: .any)["document-image"]
        XCTAssertTrue(image.waitForExistence(timeout: 10), "Captured image did not appear")
        XCTAssertEqual(app.staticTexts["document-dimensions"].value as? String, "320 × 200 px")

        // The app menu's Capture menu is available while the document window is open. Its
        // keyboard shortcut is exercised in testEscapeCancelsRegionSelectionAndKeepsDocument.
        let captureMenu = app.menuBars.menuBarItems["Capture"]
        XCTAssertTrue(captureMenu.waitForExistence(timeout: 5))
        for title in ["Capture Region…", "Capture Window…", "Capture Display", "Import Screenshot…"] {
            XCTAssertTrue(captureMenu.menuItems[title].exists, "\(title) missing from the Capture menu")
        }
    }

    @MainActor
    func testEscapeCancelsRegionSelectionAndKeepsDocument() {
        launch(permission: "granted")
        chooseFromPopoverCaptureMenu("capture-display-button")
        let image = app.descendants(matching: .any)["document-image"]
        XCTAssertTrue(image.waitForExistence(timeout: 10))

        app.typeKey("1", modifierFlags: [.command, .option])
        let hint = app.descendants(matching: .any)["capture-selection-hint"]
        XCTAssertTrue(hint.waitForExistence(timeout: 5), "Region selection did not appear")
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(hint.waitForNonExistence(timeout: 5), "Escape did not end the selection")

        XCTAssertTrue(image.waitForExistence(timeout: 5), "The open document must be kept")
        XCTAssertFalse(app.staticTexts["capture-error-message"].exists, "Cancel shows no error")
        XCTAssertFalse(app.descendants(matching: .any)["permission-guidance"].exists)
    }

    @MainActor
    func testDeniedPermissionShowsSettingsRecoveryWithoutCapturing() {
        launch(permission: "denied")
        chooseFromPopoverCaptureMenu("capture-region-button")

        let guidance = app.descendants(matching: .any)["permission-guidance"]
        XCTAssertTrue(guidance.waitForExistence(timeout: 10))
        XCTAssertTrue((app.staticTexts["permission-message"].value as? String ?? "").contains("Screen & System Audio Recording"))
        XCTAssertTrue(app.buttons["permission-open-settings"].exists)
        XCTAssertTrue(app.buttons["permission-check-again"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["capture-selection-hint"].exists,
                       "No selection overlay without permission")
        XCTAssertFalse(app.descendants(matching: .any)["document-image"].exists)
    }

    @MainActor
    func testRestrictedPermissionExplainsWithoutSettingsLink() {
        launch(permission: "restricted")
        chooseFromPopoverCaptureMenu("capture-display-button")

        let guidance = app.descendants(matching: .any)["permission-guidance"]
        XCTAssertTrue(guidance.waitForExistence(timeout: 10))
        XCTAssertTrue((app.staticTexts["permission-message"].value as? String ?? "").contains("administrator"))
        XCTAssertFalse(app.buttons["permission-open-settings"].exists)
    }

    @MainActor
    func testShortcutSettingsEnableConflictAndDisable() {
        launch(permission: "granted")
        openMenuBarPopover()
        app.buttons["settings-button"].click()

        let toggle = app.checkBoxes["shortcut-enabled-toggle"].exists
            ? app.checkBoxes["shortcut-enabled-toggle"] : app.switches["shortcut-enabled-toggle"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 10), "Settings did not open")
        XCTAssertEqual(toggle.value as? Int, 0, "The shortcut must be off until the user enables it")
        XCTAssertEqual(app.staticTexts["shortcut-display"].value as? String, "Option Shift Command R")

        toggle.click()
        XCTAssertEqual(toggle.value as? Int, 1)

        // A combination another app holds is refused, and the working one stays.
        app.buttons["shortcut-change-button"].click()
        app.typeKey("k", modifierFlags: [.control, .option, .command])
        let problem = app.descendants(matching: .any)["shortcut-problem-message"]
        XCTAssertTrue(problem.waitForExistence(timeout: 5))
        XCTAssertTrue(waitForText(of: problem, containing: "Another app"))
        XCTAssertEqual(app.staticTexts["shortcut-display"].value as? String, "Option Shift Command R")

        // A shortcut macOS uses is refused too. The fake catalog reserves ⌃⌥⌘J, so the test
        // never types a real system shortcut such as ⇧⌘3.
        app.buttons["shortcut-change-button"].click()
        app.typeKey("j", modifierFlags: [.control, .option, .command])
        XCTAssertTrue(waitForText(of: problem, containing: "macOS already uses"))

        toggle.click()
        XCTAssertEqual(toggle.value as? Int, 0)
        XCTAssertTrue(app.staticTexts["settings-capture-alternatives"].exists)
    }

    // MARK: - Helpers

    /// SwiftUI exposes text as the element's value or label depending on the control.
    private func waitForText(of element: XCUIElement, containing text: String, timeout: TimeInterval = 5) -> Bool {
        let predicate = NSPredicate(format: "value CONTAINS %@ OR label CONTAINS %@", text, text)
        return XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: predicate, object: element)],
                              timeout: timeout) == .completed
    }

    private func openMenuBarPopover() {
        let statusItem = app.statusItems.firstMatch
        XCTAssertTrue(statusItem.waitForExistence(timeout: 10), "Status item not found")
        statusItem.click()
        XCTAssertTrue(app.buttons["import-screenshot-button"].waitForExistence(timeout: 5))
    }

    private func chooseFromPopoverCaptureMenu(_ identifier: String) {
        openMenuBarPopover()
        let menu = app.descendants(matching: .any)["capture-screenshot-button"]
        XCTAssertTrue(menu.waitForExistence(timeout: 5))
        menu.click()
        let item = app.descendants(matching: .any)[identifier]
        XCTAssertTrue(item.waitForExistence(timeout: 5), "\(identifier) not in the Capture menu")
        item.click()
    }
}
