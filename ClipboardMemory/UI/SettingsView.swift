import AppKit
import KeyboardShortcuts
import ServiceManagement
import SwiftUI

struct SettingsView: View {
    @Bindable var store: HistoryStore
    var monitor: ClipboardMonitor

    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var launchMessage: String?
    @State private var usage: Int64 = 0
    @State private var confirmClear = false
    @State private var isUpdatingLaunch = false

    var body: some View {
        Form {
            Section {
                KeyboardShortcutsRecorder()
                Text("In other apps, ⇧⌘V pastes and matches style. The shortcut does not fire while the cursor is in a password field, because macOS turns on secure input.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Stepper(value: $store.historyLimit, in: 50...1000, step: 50) {
                    Text("Unpinned items: \(store.historyLimit)")
                }
                Toggle("Don’t save passwords", isOn: $store.redactSecrets)
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, enabled in
                        updateLaunchAtLogin(enabled)
                    }
                if let launchMessage {
                    Text(launchMessage)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }

            Section {
                LabeledContent("Disk usage") {
                    Text(byteCount(usage))
                }
                Button("Clear history") { confirmClear = true }
                    .disabled(store.unpinnedCount == 0)
            }

            if let notice = monitor.accessNotice {
                Section {
                    Text(notice.message)
                        .font(.callout)
                    Button("Open System Settings") {
                        SystemSettings.openPasteboardPrivacy()
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 560, height: 520)
        .onAppear { usage = store.diskUsageBytes() }
        .alert("Clear history?", isPresented: $confirmClear) {
            Button("Delete", role: .destructive) {
                store.clearUnpinned()
                usage = store.diskUsageBytes()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This deletes \(store.unpinnedCount) unpinned items from today. Pinned items and earlier days stay.")
        }
    }

    private func updateLaunchAtLogin(_ enabled: Bool) {
        guard !isUpdatingLaunch else { return }
        isUpdatingLaunch = true
        defer { isUpdatingLaunch = false }
        do {
            if enabled {
                guard AppLocation.isInstalledInApplications else {
                    throw LaunchAtLoginError.notInstalled
                }
                try SMAppService.mainApp.register()
                launchMessage = nil
            } else {
                try SMAppService.mainApp.unregister()
                launchMessage = nil
            }
        } catch {
            launchMessage = "Launch at login works for a copy in the Applications folder. Install the app with make install."
            let actual = SMAppService.mainApp.status == .enabled
            if launchAtLogin != actual {
                launchAtLogin = actual
            }
        }
    }

    private func byteCount(_ value: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: value)
    }
}

private struct KeyboardShortcutsRecorder: View {
    var body: some View {
        KeyboardShortcuts.Recorder("Shortcut", name: .togglePanel)
    }
}

enum SystemSettings {
    static func openPasteboardPrivacy() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Pasteboard") else { return }
        NSWorkspace.shared.open(url)
    }
}

enum AppLocation {
    static var isInstalledInApplications: Bool {
        Bundle.main.bundlePath.hasPrefix("/Applications/")
    }
}

private enum LaunchAtLoginError: Error {
    case notInstalled
}
