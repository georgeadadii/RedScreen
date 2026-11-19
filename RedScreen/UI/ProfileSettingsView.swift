import AppKit
import RedScreenCore
import SwiftUI

/// Settings › Detection Profile: choose, create, edit, delete, import, and export profiles.
/// Any profile that may show fewer findings than Balanced needs deliberate confirmation.
struct ProfileSettings: View {
    let model: AppModel

    @State private var pendingProfile: DetectionProfile?
    @State private var editing: ProfileDraft?
    @State private var problem: String?

    private var profiles: DetectionProfileLibrary { model.profiles }

    var body: some View {
        Picker("Profile", selection: Binding(get: { profiles.selected.name }, set: choose)) {
            ForEach(profiles.allProfiles, id: \.name) { profile in
                Text(profile.isBuiltIn ? "\(profile.name) (built-in)" : profile.name).tag(profile.name)
            }
        }
        .accessibilityIdentifier("profile-picker")

        Text(profiles.selected.explanation)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("profile-explanation")
        if profiles.selected.reducesCoverage {
            Label("This profile may show fewer findings than Balanced.", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .accessibilityIdentifier("profile-coverage-warning")
        }
        if profiles.skippedStoredProfiles > 0 {
            Text("\(profiles.skippedStoredProfiles) saved profile(s) were invalid and were not loaded.")
                .font(.caption).foregroundStyle(.orange)
        }

        HStack {
            Button("New…") { editing = ProfileDraft(profile: newProfile(), original: nil) }
                .accessibilityIdentifier("profile-new")
            Button("Edit…") { editing = ProfileDraft(profile: profiles.selected, original: profiles.selected.name) }
                .disabled(profiles.selected.isBuiltIn)
                .accessibilityIdentifier("profile-edit")
            Button("Delete", role: .destructive) { profiles.delete(profiles.selected); model.refreshSelectedProfile() }
                .disabled(profiles.selected.isBuiltIn)
                .accessibilityIdentifier("profile-delete")
            Spacer()
            Button("Import…", action: importProfile)
                .accessibilityIdentifier("profile-import")
            Button("Export…") {
                do { try model.exportProfile(profiles.selected) } catch {
                    problem = (error as? ProfileError)?.issues.joined(separator: "\n") ?? "The profile couldn't be exported."
                }
            }
            .accessibilityIdentifier("profile-export")
        }

        if let problem {
            Text(problem)
                .font(.caption)
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("profile-problem")
        }

        Text("Profiles hold settings only: thresholds, which rules are on, placeholder values to ignore, and "
             + "custom rules. They never contain screenshots, recognized text, or found values, so they are safe "
             + "to read and share as plain text.")
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .alert("Use a profile that may expose content?", isPresented: Binding(
                get: { pendingProfile != nil }, set: { if !$0 { pendingProfile = nil } }
            ), presenting: pendingProfile) { profile in
                Button("Use \(profile.name)", role: .destructive) {
                    model.useProfile(profile)
                    pendingProfile = nil
                }
                Button("Keep \(profiles.selected.name)", role: .cancel) { pendingProfile = nil }
            } message: { profile in
                Text("Compared with Balanced, \"\(profile.name)\" may leave secrets unredacted:\n\n"
                     + profile.coverageReductions.map { "• \($0)" }.joined(separator: "\n"))
            }
            .sheet(item: $editing) { draft in
                ProfileEditor(model: model, draft: draft) { editing = nil }
            }
    }

    private func choose(_ name: String) {
        guard let profile = profiles.profile(named: name), profile.name != profiles.selected.name else { return }
        problem = nil
        if profile.reducesCoverage {
            pendingProfile = profile
        } else {
            model.useProfile(profile)
        }
    }

    private func importProfile() {
        problem = nil
        switch model.chooseProfileToImport() {
        case .success(let profile):
            // Opened in the editor, so the user reviews it before anything is saved.
            editing = ProfileDraft(profile: profile, original: nil)
        case .failure(let error):
            problem = "That profile can't be imported:\n" + error.issues.map { "• \($0)" }.joined(separator: "\n")
        case nil:
            break
        }
    }

    private func newProfile() -> DetectionProfile {
        var name = "My Profile"
        var counter = 2
        while profiles.profile(named: name) != nil {
            name = "My Profile \(counter)"
            counter += 1
        }
        var profile = profiles.selected
        profile.name = name
        return profile
    }
}

struct ProfileDraft: Identifiable {
    let id = UUID()
    var profile: DetectionProfile
    /// The name of the profile being edited, or nil for a new or imported profile.
    let original: String?
}

/// Edits one profile with live validation. Saving a profile that reduces coverage needs
/// confirmation listing exactly what it hides.
struct ProfileEditor: View {
    let model: AppModel
    @State var draft: ProfileDraft
    let dismiss: () -> Void

    @State private var placeholderText = ""
    @State private var saveIssues: [String] = []
    @State private var confirmingReduction = false

    private var issues: [String] { DetectionProfileCodec.validate(draft.profile) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Form {
                Section("Profile") {
                    TextField("Name", text: $draft.profile.name)
                        .accessibilityIdentifier("profile-name-field")
                    Stepper("Redact automatically from \(draft.profile.likelyThreshold)%",
                            value: $draft.profile.likelyThreshold, in: 1...100)
                    Stepper("Show for review from \(draft.profile.reviewThreshold)%",
                            value: $draft.profile.reviewThreshold, in: 1...100)
                }
                Section("Built-in Rules") {
                    ForEach(BuiltInDetectionRule.ids, id: \.self) { rule in
                        Toggle(rule, isOn: Binding(
                            get: { !draft.profile.disabledRules.contains(rule) },
                            set: { on in
                                if on { draft.profile.disabledRules.remove(rule) } else { draft.profile.disabledRules.insert(rule) }
                            }
                        ))
                        .font(.callout.monospaced())
                    }
                }
                Section("Placeholders to Ignore") {
                    TextEditor(text: $placeholderText)
                        .font(.callout.monospaced())
                        .frame(minHeight: 60)
                        .onChange(of: placeholderText) { _, text in
                            draft.profile.placeholders = text.split(whereSeparator: \.isNewline)
                                .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                        }
                        .accessibilityLabel("Placeholders, one per line")
                    Text("One per line. A finding whose whole value equals a placeholder is hidden. Type "
                         + "documented placeholders only; never paste a real value.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("Custom Rules") {
                    // Index identity keeps a row (and its text field focus) stable while it is edited.
                    ForEach(draft.profile.customRules.indices, id: \.self) { index in
                        CustomRuleRow(rule: $draft.profile.customRules[index]) {
                            draft.profile.customRules.remove(at: index)
                        }
                    }
                    HStack {
                        Button("Add Token Rule") {
                            draft.profile.customRules.append(CustomDetectionRule(
                                id: "custom.token-\(draft.profile.customRules.count + 1)", kind: .token, prefix: "",
                                minimumLength: 20, maximumLength: 64, confidence: 90))
                        }
                        Button("Add Key/Value Rule") {
                            draft.profile.customRules.append(CustomDetectionRule(
                                id: "custom.key-\(draft.profile.customRules.count + 1)", kind: .keyValue, keys: [],
                                minimumLength: 8, maximumLength: 128, confidence: 85))
                        }
                    }
                }
                if !(issues + saveIssues).isEmpty {
                    Section("Fix Before Saving") {
                        ForEach(issues + saveIssues, id: \.self) { issue in
                            Label(issue, systemImage: "xmark.octagon.fill")
                                .foregroundStyle(.red)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .accessibilityIdentifier("profile-issues")
                }
            }
            .formStyle(.grouped)
            HStack {
                if draft.profile.reducesCoverage {
                    Label("Shows fewer findings than Balanced", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .font(.caption)
                }
                Spacer()
                Button("Cancel", role: .cancel, action: dismiss)
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    if draft.profile.reducesCoverage { confirmingReduction = true } else { save() }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!issues.isEmpty)
                .accessibilityIdentifier("profile-save")
            }
            .padding()
        }
        .frame(width: 560, height: 640)
        .onAppear { placeholderText = draft.profile.placeholders.joined(separator: "\n") }
        .alert("Save a profile that may expose content?", isPresented: $confirmingReduction) {
            Button("Save Anyway", role: .destructive, action: save)
            Button("Keep Editing", role: .cancel) {}
        } message: {
            Text(draft.profile.coverageReductions.map { "• \($0)" }.joined(separator: "\n"))
        }
    }

    private func save() {
        do {
            try model.profiles.save(draft.profile, replacing: draft.original)
            if model.profiles.selected.name.caseInsensitiveCompare(draft.profile.name.trimmingCharacters(in: .whitespaces)) == .orderedSame {
                model.refreshSelectedProfile()
            }
            dismiss()
        } catch let error as ProfileError {
            saveIssues = error.issues
        } catch {
            saveIssues = ["The profile couldn't be saved."]
        }
    }
}

private struct CustomRuleRow: View {
    @Binding var rule: CustomDetectionRule
    let remove: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                TextField("ID", text: $rule.id).font(.callout.monospaced())
                Picker("", selection: $rule.kind) {
                    Text("Token").tag(CustomDetectionRule.Kind.token)
                    Text("Key/Value").tag(CustomDetectionRule.Kind.keyValue)
                }
                .labelsHidden()
                .fixedSize()
                Button(role: .destructive, action: remove) { Image(systemName: "minus.circle") }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Remove rule")
            }
            if rule.kind == .token {
                HStack {
                    TextField("Prefix", text: $rule.prefix).font(.callout.monospaced())
                    Picker("Characters", selection: $rule.characters) {
                        ForEach(CustomDetectionRule.CharacterClass.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                }
            } else {
                TextField("Keys, comma-separated", text: Binding(
                    get: { rule.keys.joined(separator: ", ") },
                    set: { rule.keys = $0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } }
                ))
                .font(.callout.monospaced())
            }
            HStack {
                Stepper("Length \(rule.minimumLength)–", value: $rule.minimumLength, in: 1...512)
                Stepper("\(rule.maximumLength)", value: $rule.maximumLength, in: 1...512)
                Stepper("Confidence \(rule.confidence)%", value: $rule.confidence, in: 1...100)
            }
            .font(.caption)
        }
        .padding(.vertical, 4)
    }
}
