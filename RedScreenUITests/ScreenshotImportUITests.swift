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
