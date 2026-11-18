import AppKit
import ImageIO
import XCTest

/// End-to-end import tests using a synthetic fixture from the RedScreenCoreTests corpus.
final class ScreenshotImportUITests: XCTestCase {
    private var app: XCUIApplication!
    private var workDirectory: URL!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launch()

        workDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("RedScreenUITests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        app.terminate()
        if let workDirectory { try? FileManager.default.removeItem(at: workDirectory) }
    }

    @MainActor
    func testFileSelectionImportsFixtureAndCorruptFileKeepsDocument() throws {
        let fixture = try copiedFixture()
        let expected = try pixelSize(of: fixture)

        openMenuBarPopover()
        app.buttons["import-screenshot-button"].click()
        chooseInOpenPanel(fixture)

        let image = app.descendants(matching: .any)["document-image"]
        XCTAssertTrue(image.waitForExistence(timeout: 10), "Imported image did not appear")
        let dimensions = app.staticTexts["document-dimensions"]
        XCTAssertTrue(dimensions.waitForExistence(timeout: 5))
        XCTAssertEqual(dimensions.value as? String, "\(expected.width) × \(expected.height) px")

        // Shown upright and aspect-fit: measure the rendered (white) fixture inside the grey
        // letterbox from a screenshot of the canvas.
        let canvas = app.descendants(matching: .any)["document-drop-target"]
        let rendered = try renderedContentSize(in: canvas.screenshot().image)
        XCTAssertEqual(
            rendered.width / rendered.height,
            CGFloat(expected.width) / CGFloat(expected.height),
            accuracy: 0.03
        )
        XCTAssertFalse(app.buttons["import-screenshot-button"].isHittable, "Popover stayed open")

        // On-device OCR runs automatically and reports a count of text regions, never text.
        let recognition = app.staticTexts["recognition-status"]
        let recognized = NSPredicate(format: "value ENDSWITH 'text regions'")
        expectation(for: recognized, evaluatedWith: recognition)
        waitForExpectations(timeout: 20)
        let regions = Int((recognition.value as? String ?? "").split(separator: " ").first ?? "")
        XCTAssertGreaterThanOrEqual(regions ?? 0, 8, "Expected the fixture's lines to be found")
        app.checkBoxes["show-text-regions-toggle"].click()

        // A corrupt file reports an actionable error and leaves the open document in place.
        let corrupt = workDirectory.appendingPathComponent("corrupt.png")
        try Data("synthetic corrupt image bytes".utf8).write(to: corrupt)
        app.buttons["document-import-button"].click()
        chooseInOpenPanel(corrupt)

        let error = app.staticTexts["import-error-message"]
        XCTAssertTrue(error.waitForExistence(timeout: 10))
        XCTAssertFalse(error.label.contains(workDirectory.path))
        XCTAssertTrue(image.exists)
        XCTAssertEqual(dimensions.value as? String, "\(expected.width) × \(expected.height) px")

        // Closing the window closes the document.
        app.buttons["document-close-button"].click()
        XCTAssertTrue(image.waitForNonExistence(timeout: 5))
    }

    @MainActor
    func testDragAndDropFromFinderImportsFixture() throws {
        let fixture = try copiedFixture()
        let expected = try pixelSize(of: fixture)

        openMenuBarPopover()
        app.buttons["import-screenshot-button"].click()
        let sheet = app.sheets.firstMatch
        XCTAssertTrue(sheet.waitForExistence(timeout: 10))
        sheet.typeKey(.escape, modifierFlags: [])
        let dropZone = app.descendants(matching: .any)["document-drop-target"]
        XCTAssertTrue(dropZone.waitForExistence(timeout: 5))

        // Slide RedScreen's window to the left so part of it stays visible beside Finder.
        let window = app.windows["redscreen-document-window"]
        let titleBar = window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0))
            .withOffset(CGVector(dx: 0, dy: 12))
        titleBar.press(forDuration: 0.3, thenDragTo: titleBar.withOffset(CGVector(dx: -600, dy: 0)))

        let finder = XCUIApplication(bundleIdentifier: "com.apple.finder")
        NSWorkspace.shared.activateFileViewerSelecting([fixture])
        let fileItem = finder.descendants(matching: .any)
            .matching(NSPredicate(format: "label == %@ OR value == %@", fixture.lastPathComponent,
                                  fixture.lastPathComponent))
            .firstMatch
        guard fileItem.waitForExistence(timeout: 10) else {
            throw XCTSkip("Finder did not expose the fixture for dragging on this machine")
        }

        // Finder exposes the filename label; grab the icon just above it so Finder starts a file
        // drag rather than a rename.
        let source = fileItem.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: -1.5))

        // Drop on a part of the drop zone that Finder's window does not cover.
        let zone = dropZone.frame
        let finderFrame = finder.windows.firstMatch.frame
        let visibleMaxX = min(zone.maxX, finderFrame.minX)
        guard visibleMaxX - zone.minX >= 40 else {
            throw XCTSkip("Finder's window covers RedScreen's drop zone on this display")
        }
        let target = dropZone.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(
            dx: (visibleMaxX - zone.minX) / 2,
            dy: zone.height / 2
        ))
        source.press(forDuration: 0.6, thenDragTo: target)

        let dimensions = app.staticTexts["document-dimensions"]
        XCTAssertTrue(dimensions.waitForExistence(timeout: 10), "Dropped file was not imported")
        XCTAssertEqual(dimensions.value as? String, "\(expected.width) × \(expected.height) px")
        XCTAssertTrue(app.descendants(matching: .any)["document-image"].exists)
        finder.typeKey("w", modifierFlags: .command)
    }

    @MainActor
    func testReviewCandidateAndEditManualRectangle() throws {
        let fixture = try copiedFixture()
        openMenuBarPopover()
        app.buttons["import-screenshot-button"].click()
        chooseInOpenPanel(fixture)

        let first = app.buttons["review-candidate-0"]
        XCTAssertTrue(first.waitForExistence(timeout: 20))
        app.typeKey(.downArrow, modifierFlags: .option)
        XCTAssertFalse(first.label.contains("RSFAKE"))
        let exclude = app.buttons["review-exclude"]
        let include = app.buttons["review-include"]
        XCTAssertTrue(exclude.isEnabled)
        exclude.click()
        XCTAssertFalse(exclude.isEnabled)
        XCTAssertTrue(include.isEnabled)
        app.buttons["review-undo"].click()
        XCTAssertFalse(include.isEnabled)

        app.buttons["review-add"].click()
        let remove = app.buttons["review-delete"]
        XCTAssertTrue(remove.isEnabled)
        let image = app.images["document-image"]
        XCTAssertTrue(image.exists)
        let x = app.staticTexts["review-geometry-Horizontal position"]
        let width = app.staticTexts["review-geometry-Width"]
        XCTAssertTrue(x.exists)
        XCTAssertTrue(width.exists)
        let originalX = x.value as? String ?? x.label
        let originalWidth = width.value as? String ?? width.label
        let center = image.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        let moved = center.withOffset(CGVector(dx: 25, dy: 20))
        center.press(forDuration: 0.1, thenDragTo: moved)
        XCTAssertNotEqual(x.value as? String ?? x.label, originalX, "Dragging the center should move the rectangle")
        let y = app.staticTexts["review-geometry-Vertical position"]
        let height = app.staticTexts["review-geometry-Height"]
        let dimensions = try pixelSize(of: fixture)
        let canvas = app.descendants(matching: .any)["document-drop-target"]
        // The accessibility image element spans the canvas, including letterbox margins.
        let scale = min((canvas.frame.width - 24) / Double(dimensions.width),
                        (canvas.frame.height - 24) / Double(dimensions.height))
        func canvasPoint(x: Double, y: Double) -> XCUICoordinate {
            canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).withOffset(CGVector(
                dx: (x - Double(dimensions.width) / 2) * scale,
                dy: (y - Double(dimensions.height) / 2) * scale
            ))
        }
        func pixels(_ field: XCUIElement) throws -> Double {
            let text = field.value as? String ?? field.label
            let number = text.split(separator: ":").last?.trimmingCharacters(in: .whitespaces)
                .replacingOccurrences(of: " px", with: "")
            let formatter = NumberFormatter()
            formatter.numberStyle = .decimal
            return try XCTUnwrap(number.flatMap { formatter.number(from: $0)?.doubleValue })
        }
        let corner = try canvasPoint(x: pixels(x) + pixels(width), y: pixels(y) + pixels(height))
        corner.press(forDuration: 0.1, thenDragTo: corner.withOffset(CGVector(dx: 15, dy: 10)))
        let resizedWidth = width.value as? String ?? width.label
        XCTAssertNotEqual(resizedWidth, originalWidth, "Dragging a corner should resize the rectangle")
        app.buttons["review-undo"].click()
        XCTAssertEqual(width.value as? String ?? width.label, originalWidth)
        app.buttons["review-redo"].click()
        XCTAssertEqual(width.value as? String ?? width.label, resizedWidth)
        remove.click()
        XCTAssertFalse(remove.exists)
        app.buttons["review-undo"].click()
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Manual rectangle")).firstMatch.exists)
        remove.click()
        app.radioButtons["Draw"].click()
        let start = canvasPoint(x: Double(dimensions.width) * 0.25, y: Double(dimensions.height) * 0.25)
        let end = canvasPoint(x: Double(dimensions.width) * 0.4, y: Double(dimensions.height) * 0.4)
        start.press(forDuration: 0.1, thenDragTo: end)
        XCTAssertTrue(remove.exists, "Drawing should add and select a manual rectangle")

        let preview = app.buttons["review-preview"]
        XCTAssertFalse(preview.isEnabled)
        XCTAssertFalse(app.buttons["export-copy"].exists, "Output actions require the flattened preview")
        XCTAssertFalse(app.buttons["export-save"].exists)
        let pending = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Pending review")).firstMatch
        XCTAssertTrue(pending.exists)
        pending.click()
        include.click()
        XCTAssertTrue(preview.isEnabled)
        preview.click()
        expectation(for: NSPredicate(format: "label == %@", "Back to Review"), evaluatedWith: preview)
        waitForExpectations(timeout: 10)
        XCTAssertEqual(image.label, "Redacted preview")

        // Copy places only the flattened render on the clipboard, as PNG image data.
        NSPasteboard.general.clearContents()
        let copy = app.buttons["export-copy"]
        XCTAssertTrue(copy.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["export-save"].exists)
        copy.click()
        let status = app.staticTexts["export-status"]
        XCTAssertTrue(status.waitForExistence(timeout: 5))
        XCTAssertEqual(status.value as? String ?? status.label, "Copied the redacted image.")
        let items = try XCTUnwrap(NSPasteboard.general.pasteboardItems)
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items.first?.types, [.png])
        let png = try XCTUnwrap(NSPasteboard.general.data(forType: .png))
        let source = try XCTUnwrap(CGImageSourceCreateWithData(png as CFData, nil))
        let copied = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertEqual(copied.width, dimensions.width)
        XCTAssertEqual(copied.height, dimensions.height)
        // The rectangle drawn from 25% to 40% of the image is opaque black in the copy.
        let bitmap = NSBitmapImageRep(cgImage: copied)
        let drawn = try XCTUnwrap(bitmap.colorAt(x: dimensions.width * 13 / 40, y: dimensions.height * 13 / 40))
        XCTAssertEqual(drawn.redComponent, 0, accuracy: 0.01)
        XCTAssertEqual(drawn.greenComponent, 0, accuracy: 0.01)
        XCTAssertEqual(drawn.blueComponent, 0, accuracy: 0.01)
        XCTAssertEqual(drawn.alphaComponent, 1, accuracy: 0.01)

        // Save As writes the same flattened PNG through the sandboxed Save panel, without the
        // source filename and without any EXIF or text chunk.
        app.buttons["export-save"].click()
        let saved = workDirectory.appendingPathComponent("ui-redacted.png")
        chooseInSavePanel(saved)
        expectation(for: NSPredicate(format: "value == %@", "Saved the redacted image."), evaluatedWith: status)
        waitForExpectations(timeout: 10)
        let file = try Data(contentsOf: saved)
        XCTAssertEqual(file, png, "Saved and copied output are the same scrubbed encoding")
        XCTAssertFalse(String(decoding: file, as: UTF8.self).contains("eXIf"))
        XCTAssertFalse(String(decoding: file, as: UTF8.self).contains(fixture.deletingPathExtension().lastPathComponent))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: workDirectory.path).filter {
            $0.hasPrefix("ui-redacted")
        }, ["ui-redacted.png"])

        // Returning to review removes every output action.
        preview.click()
        XCTAssertTrue(copy.waitForNonExistence(timeout: 5))
        NSPasteboard.general.clearContents()
    }

    // MARK: - Helpers

    private func openMenuBarPopover() {
        let statusItem = app.statusItems.firstMatch
        XCTAssertTrue(statusItem.waitForExistence(timeout: 10), "Status item not found")
        statusItem.click()
        XCTAssertTrue(app.buttons["import-screenshot-button"].waitForExistence(timeout: 5))
    }

    /// Drives the sandbox Open panel through Go to Folder with a full file path.
    private func chooseInOpenPanel(_ url: URL) {
        let sheet = app.sheets.firstMatch
        XCTAssertTrue(sheet.waitForExistence(timeout: 10), "Open panel did not appear")
        sheet.typeKey("g", modifierFlags: [.command, .shift])
        sleep(1)
        app.typeText(url.path)
        sleep(1)
        app.typeKey(.return, modifierFlags: [])
        sleep(1)
        app.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(sheet.waitForNonExistence(timeout: 10), "Open panel did not close")
    }

    /// Drives the Save panel: Go to Folder for the directory, then the file name.
    private func chooseInSavePanel(_ url: URL) {
        let sheet = app.sheets.firstMatch
        XCTAssertTrue(sheet.waitForExistence(timeout: 10), "Save panel did not appear")
        let name = sheet.textFields["saveAsNameTextField"]
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        XCTAssertEqual(name.value as? String, "Redacted Screenshot.png", "Suggested name must be generic")
        sheet.typeKey("g", modifierFlags: [.command, .shift])
        sleep(1)
        app.typeText(url.deletingLastPathComponent().path)
        sleep(1)
        app.typeKey(.return, modifierFlags: [])
        sleep(1)
        name.click()
        name.typeKey("a", modifierFlags: .command)
        name.typeText(url.lastPathComponent)
        sheet.buttons["Save"].click()
        XCTAssertTrue(sheet.waitForNonExistence(timeout: 10), "Save panel did not close")
    }

    /// Width and height, in screenshot pixels, of the near-white region crossing the centre.
    private func renderedContentSize(in image: NSImage) throws -> CGSize {
        var rect = CGRect(origin: .zero, size: image.size)
        let cgImage = try XCTUnwrap(image.cgImage(forProposedRect: &rect, context: nil, hints: nil))
        let bitmap = NSBitmapImageRep(cgImage: cgImage)
        func isContent(_ x: Int, _ y: Int) -> Bool {
            guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { return false }
            return color.redComponent > 0.95 && color.greenComponent > 0.95
                && color.blueComponent > 0.95
        }
        let midX = bitmap.pixelsWide / 2
        let midY = bitmap.pixelsHigh / 2
        let xs = (0..<bitmap.pixelsWide).filter { isContent($0, midY) }
        let ys = (0..<bitmap.pixelsHigh).filter { isContent(midX, $0) }
        let minX = try XCTUnwrap(xs.first), maxX = try XCTUnwrap(xs.last)
        let minY = try XCTUnwrap(ys.first), maxY = try XCTUnwrap(ys.last)
        return CGSize(width: maxX - minX + 1, height: maxY - minY + 1)
    }

    /// Copies the bundled synthetic fixture to a per-test directory with a neutral name.
    private func copiedFixture() throws -> URL {
        let bundle = Bundle(for: Self.self)
        let source = try XCTUnwrap(
            bundle.url(forResource: "env-file-light-2x", withExtension: "png"),
            "Synthetic fixture missing from UI test bundle"
        )
        let destination = workDirectory.appendingPathComponent("synthetic-fixture.png")
        try FileManager.default.copyItem(at: source, to: destination)
        return destination
    }

    private func pixelSize(of url: URL) throws -> (width: Int, height: Int) {
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        let properties = try XCTUnwrap(
            CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        )
        return (
            try XCTUnwrap(properties[kCGImagePropertyPixelWidth] as? Int),
            try XCTUnwrap(properties[kCGImagePropertyPixelHeight] as? Int)
        )
    }
}
