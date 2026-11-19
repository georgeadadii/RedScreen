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

    /// RED-11: the region path end to end with the overlay: dragging captures a region, and Return
    /// captures the display instead. Each replaces the open document.
    @MainActor
    func testRegionDragAndReturnEachOpenANewCapture() {
        launch(permission: "granted")
        chooseFromPopoverCaptureMenu("capture-display-button")
        let dimensions = app.staticTexts["document-dimensions"]
        XCTAssertTrue(dimensions.waitForExistence(timeout: 10))
        XCTAssertEqual(dimensions.value as? String, "320 × 200 px")

        app.typeKey("1", modifierFlags: [.command, .option])
        let hint = app.descendants(matching: .any)["capture-selection-hint"].firstMatch
        XCTAssertTrue(hint.waitForExistence(timeout: 5))
        let start = hint.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0)).withOffset(CGVector(dx: 0, dy: 120))
        let end = start.withOffset(CGVector(dx: 160, dy: 110))
        start.press(forDuration: 0.1, thenDragTo: end)
        XCTAssertTrue(hint.waitForNonExistence(timeout: 5))
        XCTAssertTrue(waitForText(of: dimensions, containing: "240 × 160 px", timeout: 10), "Region capture did not open")

        app.typeKey("1", modifierFlags: [.command, .option])
        XCTAssertTrue(hint.waitForExistence(timeout: 5))
        app.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(hint.waitForNonExistence(timeout: 5))
        XCTAssertTrue(waitForText(of: dimensions, containing: "320 × 200 px", timeout: 10), "Return did not capture the display")
    }

    /// Switching to another app during a selection ends it, without capturing or losing the
    /// open document.
    @MainActor
    func testDeactivationEndsTheSelectionAndKeepsTheDocument() {
        launch(permission: "granted")
        chooseFromPopoverCaptureMenu("capture-display-button")
        let dimensions = app.staticTexts["document-dimensions"]
        XCTAssertTrue(dimensions.waitForExistence(timeout: 10))

        app.typeKey("1", modifierFlags: [.command, .option])
        let hint = app.descendants(matching: .any)["capture-selection-hint"].firstMatch
        XCTAssertTrue(hint.waitForExistence(timeout: 5))
        XCUIApplication(bundleIdentifier: "com.apple.finder").activate()
        XCTAssertTrue(hint.waitForNonExistence(timeout: 5), "The overlay stayed up after RedScreen lost focus")

        app.activate()
        XCTAssertTrue(dimensions.waitForExistence(timeout: 5))
        XCTAssertEqual(dimensions.value as? String, "320 × 200 px", "The open document must be kept")
        XCTAssertFalse(app.staticTexts["capture-error-message"].exists, "Leaving the selection is not an error")
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
        let askAgain = app.buttons["permission-request-again"]
        XCTAssertTrue(askAgain.exists)
        askAgain.click()
        XCTAssertTrue(guidance.waitForExistence(timeout: 2), "Still denied: the guidance stays")
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
        XCTAssertFalse(app.buttons["permission-request-again"].exists, "Asking again cannot lift a policy")
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

    /// RED-13: VS Code hints are off by default; turning them on starts the listener in the
    /// sandboxed app, and turning them off stops it and removes the pairing file.
    @MainActor
    func testEditorHintsToggleStartsAndStopsTheListener() {
        launch(permission: "granted")
        openMenuBarPopover()
        app.buttons["settings-button"].click()
        let toggle = app.checkBoxes["editor-hints-toggle"].exists
            ? app.checkBoxes["editor-hints-toggle"] : app.switches["editor-hints-toggle"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 10))
        XCTAssertEqual(toggle.value as? Int, 0, "Hints are off until the user turns them on")
        let status = app.staticTexts["editor-hints-status"]
        XCTAssertEqual(status.value as? String, "Off")

        toggle.click()
        XCTAssertTrue(waitForText(of: status, containing: "Waiting for VS Code"))
        toggle.click()
        XCTAssertTrue(waitForText(of: status, containing: "Off"))
    }

    /// RED-14: choosing a profile that may expose content needs confirmation; cancelling keeps
    /// the current one. Profiles that only add coverage switch directly.
    @MainActor
    func testProfileThatReducesCoverageNeedsConfirmation() {
        launch(permission: "granted", extra: ["-RedScreenUITestProfiles", "YES"])
        openSettings()
        let picker = app.popUpButtons["profile-picker"]
        XCTAssertTrue(picker.waitForExistence(timeout: 10))
        XCTAssertEqual(picker.value as? String, "Balanced (built-in)")

        choose("Fewer Findings", in: picker)
        let alert = app.sheets.firstMatch.exists ? app.sheets.firstMatch : app.dialogs.firstMatch
        XCTAssertTrue(app.buttons["Keep Balanced"].waitForExistence(timeout: 5), "A reducing profile asks first")
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "value CONTAINS 'high-entropy.contextual' OR label CONTAINS 'high-entropy.contextual'")).firstMatch.exists
                      || alert.debugDescription.contains("high-entropy.contextual"), "The warning lists what is hidden")
        app.buttons["Keep Balanced"].click()
        XCTAssertTrue(waitForText(of: picker, containing: "Balanced"))
        XCTAssertFalse(app.staticTexts["profile-coverage-warning"].exists)

        choose("Fewer Findings", in: picker)
        app.buttons["Use Fewer Findings"].click()
        XCTAssertTrue(waitForText(of: picker, containing: "Fewer Findings"))
        XCTAssertTrue(app.descendants(matching: .any)["profile-coverage-warning"].waitForExistence(timeout: 5))

        choose("Conservative (built-in)", in: picker)
        XCTAssertTrue(waitForText(of: picker, containing: "Conservative"), "Conservative switches without asking")
        XCTAssertFalse(app.buttons["Keep Conservative"].exists)
    }

    /// RED-14: changing profile re-evaluates the open document and keeps manual rectangles.
    @MainActor
    func testProfileChangeReevaluatesTheOpenDocumentAndKeepsManualRectangles() {
        launch(permission: "granted")
        chooseFromPopoverCaptureMenu("capture-display-button")
        let profileLabel = app.staticTexts["document-profile"]
        XCTAssertTrue(waitForText(of: profileLabel, containing: "Profile: Balanced", timeout: 15))
        app.buttons["review-add"].click()
        let manual = app.buttons["review-candidate-0"]
        XCTAssertTrue(manual.waitForExistence(timeout: 5))

        openSettings()
        let picker = app.popUpButtons["profile-picker"]
        XCTAssertTrue(picker.waitForExistence(timeout: 10))
        choose("Conservative (built-in)", in: picker)
        XCTAssertTrue(waitForText(of: profileLabel, containing: "Profile: Conservative", timeout: 10),
                      "The open document was re-evaluated with the new profile")
        XCTAssertTrue(manual.exists, "The manual rectangle is kept")
    }

    private func openSettings() {
        openMenuBarPopover()
        app.buttons["settings-button"].click()
    }

    private func choose(_ title: String, in picker: XCUIElement) {
        picker.click()
        let item = app.menuItems[title]
        XCTAssertTrue(item.waitForExistence(timeout: 5), "\(title) not in the profile picker")
        item.click()
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
