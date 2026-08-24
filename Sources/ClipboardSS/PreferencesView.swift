import SwiftUI

struct PreferencesView: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var permissionRefreshID = UUID()

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("Preferences")
                    .font(.title3.weight(.semibold))
                Spacer()
                Button("Done") {
                    dismiss()
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Keyboard Shortcuts")
                    .font(.headline)
                ShortcutRecorderView(
                    title: "Clipboard window",
                    shortcut: clipboardShortcutBinding,
                    allowClear: false
                )
                ShortcutRecorderView(
                    title: "Screenshot capture",
                    shortcut: screenshotShortcutBinding,
                    allowClear: true
                )
                ShortcutRecorderView(
                    title: "Screen text selector",
                    shortcut: screenTextShortcutBinding,
                    allowClear: true
                )
                Text("Click a shortcut field, then press the keys to use. Shortcut changes apply immediately.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Permissions")
                    .font(.headline)
                PermissionRow(
                    title: "Accessibility",
                    status: "Needed to paste clips into other apps.",
                    permission: .accessibility,
                    refreshID: $permissionRefreshID
                )
                PermissionRow(
                    title: "Screen Recording",
                    status: "Needed for screenshot capture and screen text OCR fallback.",
                    permission: .screenRecording,
                    refreshID: $permissionRefreshID
                )
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Startup")
                    .font(.headline)
                Toggle("Launch ClipboardSS when you log in", isOn: launchAtLoginBinding)
                Text("Enabled by default so clipboard history is available after restart.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Received files").font(.headline)
                Text(ReceiveSettings.resolvedDirectory().path)
                    .font(.caption.monospaced()).lineLimit(1).truncationMode(.middle)
                HStack {
                    Button("Change…") {
                        if let folder = ReceiveSettings.chooseDirectory() {
                            ReceiveSettings.path = folder.path
                            ReceiveSettings.mode = .defaultFolder
                        }
                    }
                    Toggle("Ask every time", isOn: Binding(
                        get: { ReceiveSettings.mode == .askEveryTime },
                        set: { ReceiveSettings.mode = $0 ? .askEveryTime : .defaultFolder }
                    ))
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Help")
                    .font(.headline)
                Button("Show Tour") {
                    dismiss()
                    model.restartCoachMarks()
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Storage")
                    .font(.headline)
                Text("Unpinned clips older than 7 days are removed automatically. Pinned clips stay until you delete or unpin them.")
                    .foregroundStyle(.secondary)
                Text(model.store.storageDirectory.path)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(22)
        .frame(width: 520)
    }

    private var clipboardShortcutBinding: Binding<KeyboardShortcut?> {
        Binding(
            get: { model.clipboardShortcut },
            set: { shortcut in
                if let shortcut {
                    model.setClipboardShortcut(shortcut)
                }
            }
        )
    }

    private var screenshotShortcutBinding: Binding<KeyboardShortcut?> {
        Binding(
            get: { model.screenshotShortcut },
            set: { model.setScreenshotShortcut($0) }
        )
    }

    private var screenTextShortcutBinding: Binding<KeyboardShortcut?> {
        Binding(
            get: { model.screenTextShortcut },
            set: { model.setScreenTextShortcut($0) }
        )
    }

    private var launchAtLoginBinding: Binding<Bool> {
        Binding(
            get: { model.launchAtLoginEnabled },
            set: { model.setLaunchAtLoginEnabled($0) }
        )
    }
}

private struct PermissionRow: View {
    let title: String
    let status: String
    let permission: AppPermission
    @Binding var refreshID: UUID

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: permission.isGranted ? "checkmark.shield" : "lock.shield")
                .foregroundStyle(permission.isGranted ? .green : .secondary)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                Text(permission.isGranted ? "Granted" : "\(status) If it is not listed, add \(permission.manualAddPath).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button(permission.isGranted ? "Open Settings" : "Grant Access") {
                if permission.isGranted {
                    permission.openSettings()
                } else if !permission.requestAccess() {
                    permission.openSettings()
                }
                refreshID = UUID()
            }
        }
        .id(refreshID)
        .padding(10)
        .background(Color.secondary.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}
