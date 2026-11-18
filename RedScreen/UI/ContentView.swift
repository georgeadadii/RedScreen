import AppKit
import SwiftUI

struct MenuBarContentView: View {
    let importScreenshot: () -> Void
    let capture: (AppModel.CaptureKind) -> Void
    let importDroppedItems: ([URL]) -> Void
    let showAbout: () -> Void
    let quit: () -> Void

    @State private var isDropTargeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header

            Divider()

            VStack(spacing: 6) {
                captureMenu
                actionButton(
                    title: "Import Screenshot…",
                    systemImage: "photo.badge.plus",
                    identifier: "import-screenshot-button",
                    action: {
                        dismissPopover()
                        importScreenshot()
                    }
                )
                .keyboardShortcut("o")
                .help("Open a PNG, JPEG, or HEIC screenshot, or drop one here.")
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(isDropTargeted ? Color.accentColor.opacity(0.18) : .clear)
                )
                .dropDestination(for: URL.self) { urls, _ in
                    dismissPopover()
                    importDroppedItems(urls)
                    return true
                } isTargeted: { isDropTargeted = $0 }
            }

            Divider()

            VStack(spacing: 6) {
                unavailableAction(
                    title: "Settings",
                    systemImage: "gearshape",
                    identifier: "settings-button",
                    availabilityText: "Not available"
                )

                actionButton(
                    title: "About",
                    systemImage: "info.circle",
                    identifier: "about-button",
                    action: showAbout
                )

                actionButton(
                    title: "Quit RedScreen",
                    systemImage: "power",
                    identifier: "quit-redscreen-button",
                    action: quit
                )
                .keyboardShortcut("q")
            }
        }
        .padding(16)
        .frame(width: 300)
    }

    private var captureMenu: some View {
        Menu {
            Button("Region…") { dismissPopover(); capture(.region) }
                .accessibilityIdentifier("capture-region-button")
            Button("Window…") { dismissPopover(); capture(.window) }
                .accessibilityIdentifier("capture-window-button")
            Button("Display") { dismissPopover(); capture(.display) }
                .accessibilityIdentifier("capture-display-button")
        } label: {
            Label("Capture Screenshot", systemImage: "camera.viewfinder")
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.visible)
        .help("Capture a region, window, or display directly into RedScreen. Nothing is saved.")
        .accessibilityIdentifier("capture-screenshot-button")
        .padding(.vertical, 5)
    }

    /// Closes the menu bar popover so it does not cover the document window.
    private func dismissPopover() {
        NSApplication.shared.keyWindow?.orderOut(nil)
    }

    private var header: some View {
        HStack(spacing: 11) {
            Image(systemName: "shield.lefthalf.filled")
                .font(.system(size: 28, weight: .semibold))
                .foregroundStyle(.red)
                .accessibilityHidden(true)

            VStack(spacing: 8) {
                Text("RedScreen")
                    .font(.headline)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("redscreen-title")

                Text("Local screenshot protection")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("redscreen-description")
            }
        }
    }

    private func unavailableAction(
        title: String,
        systemImage: String,
        identifier: String,
        availabilityText: String = "Coming soon"
    ) -> some View {
        Button(action: {}) {
            HStack {
                Label(title, systemImage: systemImage)
                Spacer()
                Text(availabilityText)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(true)
        .accessibilityIdentifier(identifier)
        .help("\(title) will be added in a later phase.")
        .padding(.vertical, 5)
    }

    private func actionButton(
        title: String,
        systemImage: String,
        identifier: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(identifier)
        .padding(.vertical, 5)
    }
}
