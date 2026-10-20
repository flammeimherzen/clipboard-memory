import AppKit
import Foundation

enum PasteboardAccessNotice: Equatable {
    case ask
    case denied

    var message: String {
        switch self {
        case .ask:
            "To save copies without a prompt every time, open Privacy & Security → Paste from Other Apps and choose Allow for Clipboard Memory."
        case .denied:
            "Clipboard access is denied. Allow it in Privacy & Security → Paste from Other Apps."
        }
    }
}

@MainActor
@Observable
final class ClipboardMonitor {
    private let store: HistoryStore
    private var timer: Timer?
    private var activityToken: NSObjectProtocol?
    private var debounceTask: Task<Void, Never>?
    private var lastChangeCount = 0
    private var pendingCount: Int?
    private(set) var accessNotice: PasteboardAccessNotice?

    init(store: HistoryStore) {
        self.store = store
    }

    func start() {
        lastChangeCount = NSPasteboard.general.changeCount
        refreshAccessNotice()
        activityToken = ProcessInfo.processInfo.beginActivity(
            options: .userInitiatedAllowingIdleSystemSleep,
            reason: "Watching the clipboard"
        )
        let timer = Timer(timeInterval: 0.3, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.poll()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        debounceTask?.cancel()
        debounceTask = nil
        if let activityToken {
            ProcessInfo.processInfo.endActivity(activityToken)
            self.activityToken = nil
        }
    }

    func noteOwnChange(_ changeCount: Int) {
        lastChangeCount = changeCount
        pendingCount = nil
        debounceTask?.cancel()
        debounceTask = nil
    }

    func refreshAccessNotice() {
        guard #available(macOS 15.4, *) else {
            accessNotice = nil
            return
        }
        switch NSPasteboard.general.accessBehavior {
        case .ask:
            accessNotice = .ask
        case .alwaysDeny:
            accessNotice = .denied
        default:
            accessNotice = nil
        }
    }

    private func poll() {
        refreshAccessNotice()
        let count = NSPasteboard.general.changeCount
        if store.isPaused {
            lastChangeCount = count
            pendingCount = nil
            debounceTask?.cancel()
            debounceTask = nil
            return
        }
        guard count != lastChangeCount, pendingCount != count else { return }
        scheduleCapture(expectedCount: count)
    }

    private func scheduleCapture(expectedCount: Int) {
        pendingCount = expectedCount
        debounceTask?.cancel()
        debounceTask = Task { @MainActor in
            do {
                try await Task.sleep(for: .milliseconds(120))
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            let latest = NSPasteboard.general.changeCount
            if latest != expectedCount {
                pendingCount = nil
                self.poll()
                return
            }
            self.capture(count: latest)
        }
    }

    private func capture(count: Int) {
        lastChangeCount = count
        pendingCount = nil
        if #available(macOS 15.4, *), NSPasteboard.general.accessBehavior == .alwaysDeny {
            return
        }

        let snapshot = ClipboardReader.snapshot(from: .general)
        let decision = ClipboardReader.decide(snapshot, redactSecrets: store.redactSecrets)
        let source = SourceApp.frontmost
        switch decision {
        case .skip:
            break
        case .text(let text):
            store.addText(text, source: source)
        case .png(let data):
            store.addImage(data: data, fileExtension: "png", source: source)
        case .jpeg(let data):
            store.addImage(data: data, fileExtension: "jpg", source: source)
        case .transcodeImage(let data):
            guard let png = ImageTranscoder.pngData(from: data)?.0 else { return }
            store.addImage(data: png, fileExtension: "png", source: source)
        }
    }
}

extension SourceApp {
    static var frontmost: SourceApp {
        let application = NSWorkspace.shared.frontmostApplication
        return SourceApp(bundleID: application?.bundleIdentifier, name: application?.localizedName)
    }
}
