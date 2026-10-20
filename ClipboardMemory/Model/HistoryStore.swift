import CryptoKit
import Foundation
import ImageIO
import os

@MainActor
@Observable
final class HistoryStore {
    static let maxImageBytes = 40 * 1024 * 1024
    static let maxTextBytes = 2 * 1024 * 1024
    static let inlineTextBytes = 32 * 1024

    private(set) var items: [ClipItem] = []
    private let root: URL
    private let defaults: UserDefaults
    private var textCache: [UUID: String] = [:]
    private var saveTask: Task<Void, Never>?
    private var saveGeneration = 0

    var historyLimit: Int {
        didSet {
            let clamped = max(1, historyLimit)
            if clamped != historyLimit {
                historyLimit = clamped
                return
            }
            defaults.set(historyLimit, forKey: Keys.limit)
            trim()
            scheduleSave()
        }
    }

    var isPaused: Bool {
        didSet { defaults.set(isPaused, forKey: Keys.paused) }
    }

    var redactSecrets: Bool {
        didSet { defaults.set(redactSecrets, forKey: Keys.redact) }
    }

    var sortedItems: [ClipItem] {
        items.sorted { lhs, rhs in
            if lhs.isPinned != rhs.isPinned { return lhs.isPinned }
            if lhs.lastUsedAt != rhs.lastUsedAt { return lhs.lastUsedAt > rhs.lastUsedAt }
            return lhs.createdAt > rhs.createdAt
        }
    }

    var unpinnedCount: Int {
        items.reduce(into: 0) { count, item in
            if !item.isPinned { count += 1 }
        }
    }

    init(root: URL? = nil, defaults: UserDefaults = .standard) {
        let resolvedRoot = root ?? Self.defaultRoot()
        self.root = resolvedRoot
        self.defaults = defaults
        self.historyLimit = defaults.object(forKey: Keys.limit) as? Int ?? 200
        self.isPaused = defaults.bool(forKey: Keys.paused)
        if defaults.object(forKey: Keys.redact) == nil {
            self.redactSecrets = true
        } else {
            self.redactSecrets = defaults.bool(forKey: Keys.redact)
        }
        try? FileManager.default.createDirectory(at: resolvedRoot, withIntermediateDirectories: true)
        load()
    }

    func addText(_ text: String, source: SourceApp?) {
        let data = Data(text.utf8)
        guard !data.isEmpty, data.count <= Self.maxTextBytes else { return }
        let hash = Self.hexHash(of: data)
        if promoteExisting(hash: hash, kind: .text, source: source) { return }

        let id = UUID()
        var inlineText: String? = text
        var textFileName: String?
        if data.count > Self.inlineTextBytes {
            let relative = "texts/\(id.uuidString).txt"
            do {
                try write(data, relative: relative)
            } catch {
                Logger.store.error("Failed to write text: \(error.localizedDescription, privacy: .public)")
                return
            }
            inlineText = nil
            textFileName = relative
        }

        items.append(
            ClipItem(
                id: id,
                kind: .text,
                text: inlineText,
                imageFileName: nil,
                textFileName: textFileName,
                pixelSize: nil,
                contentHash: hash,
                sourceAppBundleID: source?.bundleID,
                sourceAppName: source?.name,
                createdAt: Date(),
                lastUsedAt: Date(),
                isPinned: false
            )
        )
        trim()
        scheduleSave()
    }

    func addImage(data: Data, fileExtension: String, source: SourceApp?) {
        guard !data.isEmpty, data.count <= Self.maxImageBytes else { return }
        let hash = Self.hexHash(of: data)
        if promoteExisting(hash: hash, kind: .image, source: source) { return }

        let id = UUID()
        let normalizedExtension = (fileExtension == "jpg" || fileExtension == "jpeg") ? "jpg" : "png"
        let relative = "images/\(id.uuidString).\(normalizedExtension)"
        do {
            try write(data, relative: relative)
        } catch {
            Logger.store.error("Failed to write image: \(error.localizedDescription, privacy: .public)")
            return
        }

        items.append(
            ClipItem(
                id: id,
                kind: .image,
                text: nil,
                imageFileName: relative,
                textFileName: nil,
                pixelSize: Self.pixelSize(of: data),
                contentHash: hash,
                sourceAppBundleID: source?.bundleID,
                sourceAppName: source?.name,
                createdAt: Date(),
                lastUsedAt: Date(),
                isPinned: false
            )
        )
        trim()
        scheduleSave()
    }

    func text(for item: ClipItem) -> String? {
        if let text = item.text { return text }
        if let cached = textCache[item.id] { return cached }
        guard let name = item.textFileName,
              let data = try? Data(contentsOf: url(forRelative: name)),
              let text = String(data: data, encoding: .utf8) else { return nil }
        textCache[item.id] = text
        return text
    }

    func imageData(for item: ClipItem) -> Data? {
        guard let imageFileName = item.imageFileName else { return nil }
        return try? Data(contentsOf: url(forRelative: imageFileName))
    }

    func url(forRelative relative: String) -> URL {
        relative.split(separator: "/").reduce(root) { partial, component in
            partial.appending(path: String(component))
        }
    }

    func delete(id: UUID) {
        guard let item = items.first(where: { $0.id == id }) else { return }
        removeFiles(of: item)
        textCache[id] = nil
        items.removeAll { $0.id == id }
        scheduleSave()
    }

    func togglePin(id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].isPinned.toggle()
        scheduleSave()
    }

    func touch(id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].lastUsedAt = Date()
        scheduleSave()
    }

    func clearUnpinned() {
        let victims = items.filter { !$0.isPinned }
        for item in victims {
            removeFiles(of: item)
            textCache[item.id] = nil
        }
        items.removeAll { !$0.isPinned }
        scheduleSave()
    }

    func diskUsageBytes() -> Int64 {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in enumerator {
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            total += Int64(size)
        }
        return total
    }

    func flush() {
        saveGeneration += 1
        let generation = saveGeneration
        saveTask?.cancel()
        saveTask = nil
        guard let data = encodedData() else { return }
        let url = historyFileURL
        let semaphore = DispatchSemaphore(value: 0)
        Task.detached {
            await HistoryFileWriter.shared.write(data: data, url: url, generation: generation)
            semaphore.signal()
        }
        semaphore.wait()
    }

    private func promoteExisting(hash: String, kind: ClipItem.Kind, source: SourceApp?) -> Bool {
        guard let index = items.firstIndex(where: { $0.contentHash == hash && $0.kind == kind }) else {
            return false
        }
        items[index].lastUsedAt = Date()
        if let source {
            items[index].sourceAppBundleID = source.bundleID
            items[index].sourceAppName = source.name
        }
        scheduleSave()
        return true
    }

    private func trim() {
        var unpinned = items.filter { !$0.isPinned }.sorted { $0.lastUsedAt < $1.lastUsedAt }
        while unpinned.count > historyLimit {
            let victim = unpinned.removeFirst()
            removeFiles(of: victim)
            textCache[victim.id] = nil
            items.removeAll { $0.id == victim.id }
        }
    }

    private func removeFiles(of item: ClipItem) {
        for name in [item.imageFileName, item.textFileName].compactMap({ $0 }) {
            try? FileManager.default.removeItem(at: url(forRelative: name))
        }
    }

    private func write(_ data: Data, relative: String) throws {
        let url = url(forRelative: relative)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: url, options: .atomic)
    }

    private func scheduleSave() {
        saveGeneration += 1
        let generation = saveGeneration
        saveTask?.cancel()
        saveTask = Task { @MainActor in
            do {
                try await Task.sleep(for: .milliseconds(500))
            } catch {
                return
            }
            guard !Task.isCancelled, generation == self.saveGeneration else { return }
            guard let data = self.encodedData() else { return }
            let url = self.historyFileURL
            Task.detached {
                await HistoryFileWriter.shared.write(data: data, url: url, generation: generation)
            }
        }
    }

    private func load() {
        let url = historyFileURL
        if FileManager.default.fileExists(atPath: url.path) {
            do {
                let data = try Data(contentsOf: url)
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601
                items = try decoder.decode([ClipItem].self, from: data)
            } catch {
                let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
                let broken = root.appending(path: "history.json.broken-\(stamp)")
                try? FileManager.default.moveItem(at: url, to: broken)
                items = []
                Logger.store.error("History file was corrupt and moved aside: \(error.localizedDescription, privacy: .public)")
            }
        }
        cleanupOrphans()
    }

    private func cleanupOrphans() {
        let referenced = Set(items.compactMap(\.imageFileName) + items.compactMap(\.textFileName))
        for folder in ["images", "texts"] {
            let directory = root.appending(path: folder)
            guard let files = try? FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil
            ) else { continue }
            for file in files {
                let relative = "\(folder)/\(file.lastPathComponent)"
                if !referenced.contains(relative) {
                    try? FileManager.default.removeItem(at: file)
                }
            }
        }
    }

    private var historyFileURL: URL {
        root.appending(path: "history.json")
    }

    private func encodedData() -> Data? {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try? encoder.encode(items)
    }

    private static func defaultRoot() -> URL {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "ClipboardMemory", directoryHint: .isDirectory)
    }

    private static func hexHash(of data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func pixelSize(of data: Data) -> PixelSize? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        else { return nil }
        guard let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue
        else { return nil }
        return PixelSize(width: width, height: height)
    }

    private enum Keys {
        static let limit = "historyLimit"
        static let paused = "isPaused"
        static let redact = "redactSecrets"
    }
}

private actor HistoryFileWriter {
    static let shared = HistoryFileWriter()
    private var appliedGeneration = 0

    func write(data: Data, url: URL, generation: Int) {
        guard generation >= appliedGeneration else { return }
        appliedGeneration = generation
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            Logger.store.error("Failed to save history: \(error.localizedDescription, privacy: .public)")
        }
    }
}

private enum Logger {
    static let store = os.Logger(subsystem: "com.belzephyrus.ClipboardMemory", category: "store")
}
