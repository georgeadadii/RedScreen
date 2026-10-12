import XCTest

@testable import RedScreenCore

final class RedScreenCoreSmokeTests: XCTestCase {
    func testScreenshotImagePreservesInMemoryData() {
        let bytes = Data([0x52, 0x53])

        let image = ScreenshotImage(data: bytes)

        XCTAssertEqual(image.data, bytes)
    }
}
