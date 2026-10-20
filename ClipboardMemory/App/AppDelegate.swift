import AppKit
import KeyboardShortcuts

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var store: HistoryStore?
    private var monitor: ClipboardMonitor?
    private var notch: NotchController?
    private var settings: SettingsWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard !LaunchEnvironment.isRunningTests else { return }
        guard Self.isOnlyCopyRunning else {
            NSApp.terminate(nil)
            return
        }

        NSApp.setActivationPolicy(.accessory)

        let store = HistoryStore()
        let monitor = ClipboardMonitor(store: store)
        let notch = NotchController(store: store, monitor: monitor)
        let settings = SettingsWindowController(store: store, monitor: monitor)

        notch.onCommit = { [weak self] item in
            self?.commit(item)
        }
        notch.onOpenSettings = { [weak self] in
            self?.openSettings()
        }
        notch.onQuit = {
            NSApp.terminate(nil)
        }

        self.store = store
        self.monitor = monitor
        self.notch = notch
        self.settings = settings

        notch.start()
        monitor.start()
        KeyboardShortcuts.onKeyDown(for: .togglePanel) { [weak self] in
            MainActor.assumeIsolated {
                self?.notch?.toggle()
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        monitor?.stop()
        store?.flush()
    }

    private func commit(_ item: ClipItem) {
        guard let store, let monitor else { return }
        if let changeCount = PasteboardWriter.write(item, using: store) {
            monitor.noteOwnChange(changeCount)
        }
        store.touch(id: item.id)
        notch?.close()
    }

    private func openSettings() {
        notch?.close()
        settings?.show()
    }

    private static var isOnlyCopyRunning: Bool {
        let bundleID = Bundle.main.bundleIdentifier ?? "com.belzephyrus.ClipboardMemory"
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .filter { $0.processIdentifier != getpid() }
        return others.isEmpty
    }
}

enum LaunchEnvironment {
    static var isRunningTests: Bool {
        let environment = ProcessInfo.processInfo.environment
        if environment["XCTestConfigurationFilePath"] != nil { return true }
        if environment["XCTestSessionIdentifier"] != nil { return true }
        if environment["XCInjectBundle"] != nil { return true }
        return ProcessInfo.processInfo.arguments.contains { argument in
            argument.contains("XCTest") || argument.contains("xctest")
        }
    }
}
