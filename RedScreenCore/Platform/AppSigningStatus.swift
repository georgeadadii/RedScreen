import Foundation
import Security

/// How the running copy of RedScreen is signed and where it lives. This decides whether macOS
/// can keep its Screen Recording permission:
///
/// - **Ad-hoc signed** ("Sign to Run Locally", no developer certificate): macOS ties the
///   permission to the exact binary, so every rebuild or reinstall looks like a new app.
/// - **Signed with a team** (Apple Development or Developer ID): the permission follows the
///   certificate and bundle ID, so it survives rebuilds.
/// - **Run from a build folder**: rebuilt constantly, and easy to confuse with another copy.
public struct AppSigningStatus: Equatable, Sendable {
    public let isAdHoc: Bool
    public let isInstalledInApplications: Bool

    public init(isAdHoc: Bool, isInstalledInApplications: Bool) {
        self.isAdHoc = isAdHoc
        self.isInstalledInApplications = isInstalledInApplications
    }

    /// The running app's status, read from its own code signature.
    public static func current(bundleURL: URL = Bundle.main.bundleURL) -> AppSigningStatus {
        AppSigningStatus(isAdHoc: runningCodeIsAdHoc(), isInstalledInApplications: isApplicationsFolder(bundleURL))
    }

    static func isApplicationsFolder(_ bundleURL: URL) -> Bool {
        let parent = bundleURL.resolvingSymlinksInPath().deletingLastPathComponent().path
        let home = FileManager.default.homeDirectoryForCurrentUser.resolvingSymlinksInPath().path
        return parent == "/Applications" || parent == home + "/Applications"
    }

    private static func runningCodeIsAdHoc() -> Bool {
        var code: SecCode?
        var staticCode: SecStaticCode?
        var info: CFDictionary?
        guard SecCodeCopySelf(SecCSFlags(), &code) == errSecSuccess, let code,
              SecCodeCopyStaticCode(code, SecCSFlags(), &staticCode) == errSecSuccess, let staticCode,
              SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let details = info as? [String: Any] else {
            return true  // Unknown: assume the fragile case, which only adds advice.
        }
        let flags = (details[kSecCodeInfoFlags as String] as? NSNumber)?.uint32Value ?? 0
        let team = details[kSecCodeInfoTeamIdentifier as String] as? String
        return flags & SecCodeSignatureFlags.adhoc.rawValue != 0 || team == nil
    }

    /// Why Screen Recording permission may not stick for this copy, and what to do; nil when
    /// this copy keeps its permission across rebuilds.
    public var permissionAdvice: String? {
        switch (isAdHoc, isInstalledInApplications) {
        case (true, false):
            "This copy of RedScreen is a development build that isn't signed with a developer certificate, "
                + "so macOS forgets its Screen Recording permission every time it is rebuilt. For a copy that "
                + "keeps it, run \"make install\" and use /Applications/RedScreen.app, and sign it with your "
                + "team (see the setup guide)."
        case (true, true):
            "This copy isn't signed with a developer certificate, so macOS forgets its Screen Recording "
                + "permission each time it is reinstalled. Allow it again after installing, or sign it with "
                + "your team to keep it."
        case (false, false):
            "You're running RedScreen from a build folder. Make sure the RedScreen you allow in System "
                + "Settings is this copy."
        case (false, true):
            nil
        }
    }
}
