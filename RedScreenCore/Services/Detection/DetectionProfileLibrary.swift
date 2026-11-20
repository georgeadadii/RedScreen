import Foundation
import Observation

/// The built-in and user profiles, and which one is in use.
///
/// User profiles are stored as plain-text profile JSON and re-validated when loaded; a stored
/// profile that no longer validates is skipped and reported, never partly applied. Selecting a
/// profile that reduces coverage is the caller's decision to confirm (`coverageReductions`).
@MainActor
@Observable
public final class DetectionProfileLibrary {
    public static let maximumUserProfiles = 20

    public private(set) var userProfiles: [DetectionProfile] = []
    public private(set) var selected: DetectionProfile = .balanced
    /// Stored profiles that failed validation when loaded.
    public private(set) var skippedStoredProfiles = 0

    @ObservationIgnored private let store: any DetectionProfileStore

    public init(store: any DetectionProfileStore) {
        self.store = store
        for document in store.savedProfileDocuments {
            if let profile = try? DetectionProfileCodec.decode(Data(document.utf8)), !contains(named: profile.name) {
                userProfiles.append(profile)
            } else {
                skippedStoredProfiles += 1
            }
        }
        if let name = store.selectedProfileName, let profile = profile(named: name) {
            selected = profile
        }
    }

    public var allProfiles: [DetectionProfile] { DetectionProfile.builtIns + userProfiles }

    public func profile(named name: String) -> DetectionProfile? {
        allProfiles.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }

    private func contains(named name: String) -> Bool { profile(named: name) != nil }

    public func select(_ profile: DetectionProfile) {
        guard let match = self.profile(named: profile.name) else { return }
        selected = match
        store.selectedProfileName = match.name
    }

    /// Adds a new user profile, or replaces the one being edited (`replacing`, by name).
    /// Throws `ProfileError` with messages to show when it is invalid or the name is taken.
    public func save(_ profile: DetectionProfile, replacing original: String? = nil) throws {
        var issues = DetectionProfileCodec.validate(profile)
        let name = profile.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let existing = userProfiles.firstIndex { $0.name.caseInsensitiveCompare(original ?? name) == .orderedSame }
        if let clash = self.profile(named: name), clash.name.caseInsensitiveCompare(original ?? "") != .orderedSame,
           !clash.isBuiltIn {
            issues.append("A profile named \"\(clash.name)\" already exists. Choose another name.")
        }
        if existing == nil, userProfiles.count >= Self.maximumUserProfiles {
            issues.append("You can keep up to \(Self.maximumUserProfiles) profiles. Delete one first.")
        }
        guard issues.isEmpty else { throw ProfileError(issues) }
        var stored = profile
        stored.name = name
        if let existing {
            let wasSelected = selected.name == userProfiles[existing].name
            userProfiles[existing] = stored
            if wasSelected { select(stored) }
        } else {
            userProfiles.append(stored)
        }
        persist()
    }

    public func delete(_ profile: DetectionProfile) {
        guard !profile.isBuiltIn else { return }
        userProfiles.removeAll { $0.name == profile.name }
        if selected.name == profile.name { select(.balanced) }
        persist()
    }

    /// Reads a profile file. It is validated but not added or selected.
    public func importProfile(from data: Data) throws -> DetectionProfile {
        try DetectionProfileCodec.decode(data)
    }

    public func exportProfile(_ profile: DetectionProfile) throws -> Data {
        try DetectionProfileCodec.encode(profile)
    }

    private func persist() {
        store.savedProfileDocuments = userProfiles.compactMap { profile in
            (try? DetectionProfileCodec.encode(profile)).map { String(decoding: $0, as: UTF8.self) }
        }
    }
}
