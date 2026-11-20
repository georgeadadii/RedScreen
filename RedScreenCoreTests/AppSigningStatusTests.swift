import Foundation
import XCTest

@testable import RedScreenCore

/// Advice about whether macOS can keep Screen Recording permission for this copy.
final class AppSigningStatusTests: XCTestCase {
    func testAdviceForEachSigningAndInstallCase() throws {
        let devBuild = try XCTUnwrap(AppSigningStatus(isAdHoc: true, isInstalledInApplications: false).permissionAdvice)
        XCTAssertTrue(devBuild.contains("every time it is rebuilt"))
        XCTAssertTrue(devBuild.contains("make install"))

        let installedAdHoc = try XCTUnwrap(AppSigningStatus(isAdHoc: true, isInstalledInApplications: true).permissionAdvice)
        XCTAssertTrue(installedAdHoc.contains("each time it is reinstalled"))

        let signedBuildFolder = try XCTUnwrap(AppSigningStatus(isAdHoc: false, isInstalledInApplications: false).permissionAdvice)
        XCTAssertTrue(signedBuildFolder.contains("build folder"))

        XCTAssertNil(AppSigningStatus(isAdHoc: false, isInstalledInApplications: true).permissionAdvice,
                     "A signed, installed copy keeps its permission: no advice")
    }

    func testApplicationsFolderDetection() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        XCTAssertTrue(AppSigningStatus.isApplicationsFolder(URL(fileURLWithPath: "/Applications/RedScreen.app")))
        XCTAssertTrue(AppSigningStatus.isApplicationsFolder(home.appendingPathComponent("Applications/RedScreen.app")))
        XCTAssertFalse(AppSigningStatus.isApplicationsFolder(URL(fileURLWithPath: "/Applications/Tools/RedScreen.app")))
        XCTAssertFalse(AppSigningStatus.isApplicationsFolder(
            URL(fileURLWithPath: "/Users/someone/src/RedScreen/.build/DerivedData/Build/Products/Debug/RedScreen.app")))
    }

    /// Reading the running process's own signature works and never throws.
    func testCurrentStatusCanBeRead() {
        let status = AppSigningStatus.current(bundleURL: URL(fileURLWithPath: "/tmp/RedScreen.app"))
        XCTAssertFalse(status.isInstalledInApplications)
    }
}
