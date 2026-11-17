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
    private(set) var archivedDays: [DayArchive] = []
    private(set) var currentDayID = ""

    private let root: URL
    private let defaults: UserDefaults
    private let calendar: Calendar
    private let now: @MainActor () -> Date
    private let dayObserver = NotificationToken()
    // Only the selected preview needs the full sidecar between view updates.
    @ObservationIgnored private var cachedText: (id: UUID, value: String)?
    private var canSaveLiveIndex = true
    private var unreadableDays = Set<String>()
    private var saveTask: Task<Void, Never>?
    private static var saveGeneration = 0
    private var isArchiving = false

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

    var currentDate: Date { now() }

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

    init(
        root: URL? = nil,
        defaults: UserDefaults = .standard,
        calendar: Calendar = .autoupdatingCurrent,
        now: @escaping @MainActor () -> Date = { Date() }
    ) {
        let resolvedRoot = root ?? Self.defaultRoot()
        self.root = resolvedRoot
        self.defaults = defaults
        self.calendar = calendar
        self.now = now
        self.historyLimit = defaults.object(forKey: Keys.limit) as? Int ?? 200
        self.isPaused = defaults.bool(forKey: Keys.paused)
        if defaults.object(forKey: Keys.redact) == nil {
            self.redactSecrets = true
        } else {
            self.redactSecrets = defaults.bool(forKey: Keys.redact)
        }
        try? FileManager.default.createDirectory(at: resolvedRoot, withIntermediateDirectories: true)
        load()
        observeDayChanges()
    }

    func addText(_ text: String, source: SourceApp?) {
        archivePastDaysIfNeeded()
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

        let timestamp = now()
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
                createdAt: timestamp,
                lastUsedAt: timestamp,
                isPinned: false
            )
        )
        trim()
        scheduleSave()
    }

    func addImage(data: Data, fileExtension: String, source: SourceApp?) {
        archivePastDaysIfNeeded()
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

        let timestamp = now()
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
                createdAt: timestamp,
                lastUsedAt: timestamp,
                isPinned: false
            )
        )
        trim()
        scheduleSave()
    }

    func text(for item: ClipItem) -> String? {
        if let text = item.text { return text }
        if cachedText?.id == item.id { return cachedText?.value }
        guard let name = item.textFileName,
              let data = try? Data(contentsOf: url(forRelative: name)),
              let text = String(data: data, encoding: .utf8) else { return nil }
        cachedText = (item.id, text)
        return text
    }

    func imageData(for item: ClipItem) -> Data? {
        guard let imageFileName = item.imageFileName else { return nil }
        return try? Data(contentsOf: url(forRelative: imageFileName), options: .mappedIfSafe)
    }

    func url(forRelative relative: String) -> URL {
        relative.split(separator: "/").reduce(root) { partial, component in
            partial.appending(path: String(component))
        }
    }

    func delete(id: UUID) {
        if let item = items.first(where: { $0.id == id }) {
            removeFiles(of: item)
            if cachedText?.id == id { cachedText = nil }
            items.removeAll { $0.id == id }
            scheduleSave()
            return
        }
        guard let dayIndex = archivedDays.firstIndex(where: { $0.items.contains(where: { $0.id == id }) }),
              let item = archivedDays[dayIndex].items.first(where: { $0.id == id }) else { return }
        if cachedText?.id == id { cachedText = nil }
        var updated = archivedDays[dayIndex]
        updated.items.removeAll { $0.id == id }
        if updated.items.isEmpty {
            let dayID = archivedDays[dayIndex].id
            archivedDays.remove(at: dayIndex)
            removeDayFolder(dayID)
        } else {
            guard writeDay(updated) else { return }
            archivedDays[dayIndex] = updated
            removeFiles(of: item)
        }
    }

    func deleteDay(id: String) {
        guard archivedDays.contains(where: { $0.id == id }) else { return }
        cachedText = nil
        archivedDays.removeAll { $0.id == id }
        removeDayFolder(id)
    }

    func togglePin(id: UUID) {
        if let index = items.firstIndex(where: { $0.id == id }) {
            items[index].isPinned.toggle()
            archivePastDaysIfNeeded()
            scheduleSave()
            return
        }
        pinArchivedItem(id: id)
    }

    func touch(id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].lastUsedAt = now()
        scheduleSave()
    }

    func clearUnpinned() {
        let victims = items.filter { !$0.isPinned }
        for item in victims {
            removeFiles(of: item)
            if cachedText?.id == item.id { cachedText = nil }
        }
        items.removeAll { !$0.isPinned }
        scheduleSave()
    }

    func archivePastDaysIfNeeded() {
        guard !isArchiving else { return }
        isArchiving = true
        defer { isArchiving = false }

        let stamp = dayID(for: now())
        if currentDayID != stamp {
            currentDayID = stamp
        }

        let todayStart = startOfDay(for: now())
        let past = items.filter { item in
            !item.isPinned && startOfDay(for: item.createdAt) < todayStart
        }
        guard !past.isEmpty else { return }

        var grouped: [String: [ClipItem]] = [:]
        for item in past {
            grouped[dayID(for: item.createdAt), default: []].append(item)
        }

        var removals: [String] = []
        var moved: Set<UUID> = []
        for (id, group) in grouped where !unreadableDays.contains(id) {
            let existingIDs = Set(archivedDays.first(where: { $0.id == id })?.items.map(\.id) ?? [])
            var fresh: [ClipItem] = []
            for item in group {
                if existingIDs.contains(item.id) {
                    queueRemovalOfSupersededFiles(item, dayID: id, removals: &removals)
                    moved.insert(item.id)
                    continue
                }
                var copy = item
                copy.imageFileName = relocate(item.imageFileName, intoDay: id, removals: &removals)
                copy.textFileName = relocate(item.textFileName, intoDay: id, removals: &removals)
                fresh.append(copy)
            }
            if merge(fresh, intoDay: id) {
                moved.formUnion(fresh.map(\.id))
            }
        }

        guard !moved.isEmpty else { return }
        items.removeAll { moved.contains($0.id) }
        sortArchivedDays()
        if flush() {
            deleteUnusedSources(removals)
        } else {
            scheduleSave()
        }
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

    @discardableResult
    func flush() -> Bool {
        Self.saveGeneration += 1
        let generation = Self.saveGeneration
        saveTask?.cancel()
        saveTask = nil
        guard let data = encodedData() else { return false }
        return HistoryFileWriter.shared.flush(data: data, url: historyFileURL, generation: generation)
    }

    private func pinArchivedItem(id: UUID) {
        guard let dayIndex = archivedDays.firstIndex(where: { $0.items.contains(where: { $0.id == id }) }),
              let itemIndex = archivedDays[dayIndex].items.firstIndex(where: { $0.id == id }) else { return }
        var item = archivedDays[dayIndex].items[itemIndex]
        var removals: [String] = []
        let image = relocateToLive(item.imageFileName, removals: &removals)
        let text = relocateToLive(item.textFileName, removals: &removals)
        guard image.succeeded, text.succeeded else { return }
        item.imageFileName = image.path
        item.textFileName = text.path
        item.isPinned = true
        item.lastUsedAt = now()
        items.append(item)
        guard flush() else {
            items.removeAll { $0.id == id }
            scheduleSave()
            return
        }

        archivedDays[dayIndex].items.remove(at: itemIndex)
        let dayID = archivedDays[dayIndex].id
        if archivedDays[dayIndex].items.isEmpty {
            archivedDays.remove(at: dayIndex)
            if liveItemsReferenceDayFolder(dayID) {
                _ = writeDay(DayArchive(id: dayID, date: date(fromDayID: dayID) ?? now(), items: []))
            } else {
                removeDayFolder(dayID)
            }
        } else {
            _ = writeDay(archivedDays[dayIndex])
            deleteUnusedSources(removals)
        }
    }

    private func promoteExisting(hash: String, kind: ClipItem.Kind, source: SourceApp?) -> Bool {
        guard let index = items.firstIndex(where: { $0.contentHash == hash && $0.kind == kind }) else {
            return false
        }
        items[index].lastUsedAt = now()
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
            if cachedText?.id == victim.id { cachedText = nil }
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
        Self.saveGeneration += 1
        let generation = Self.saveGeneration
        saveTask?.cancel()
        saveTask = Task { @MainActor in
            do {
                try await Task.sleep(for: .milliseconds(500))
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            guard let data = self.encodedData() else { return }
            HistoryFileWriter.shared.enqueue(data: data, url: self.historyFileURL, generation: generation)
        }
    }

    private func load() {
        let liveIndexLoaded = loadCurrentItems()
        // An old quarantined index may still reference sidecars after later relaunches.
        let entries = try? FileManager.default.contentsOfDirectory(atPath: root.path)
        let safeToClean = liveIndexLoaded && entries?.contains(where: { $0.hasPrefix("history.json.broken-") }) == false
        let archivesLoaded = loadArchivedDays()
        dropArchivedItemsThatAreStillLive()
        archivePastDaysIfNeeded()
        if safeToClean && archivesLoaded { cleanupOrphans() }
    }

    private func loadCurrentItems() -> Bool {
        let url = historyFileURL
        do {
            let data = try Data(contentsOf: url)
            items = try makeDecoder().decode([ClipItem].self, from: data)
            return true
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            // A previous recovery may have quarantined the index before relaunch.
        } catch is DecodingError {
            do {
                let broken = root.appending(path: "history.json.broken-\(UUID().uuidString)")
                try FileManager.default.moveItem(at: url, to: broken)
            } catch {
                canSaveLiveIndex = false
            }
            Logger.store.error("Invalid live index. Preserving clipboard files.")
        } catch {
            canSaveLiveIndex = false
            Logger.store.error("Cannot read live index: \(error.localizedDescription, privacy: .public)")
        }
        if let backup = try? Data(contentsOf: url.appendingPathExtension("backup")),
           let recovered = try? makeDecoder().decode([ClipItem].self, from: backup) {
            items = recovered
        }
        return false
    }

    private func loadArchivedDays() -> Bool {
        let daysRoot = root.appending(path: "days", directoryHint: .isDirectory)
        let folders: [URL]
        do {
            folders = try FileManager.default.contentsOfDirectory(at: daysRoot, includingPropertiesForKeys: [.isDirectoryKey])
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return true
        } catch {
            return false
        }

        var days: [DayArchive] = []
        for folder in folders {
            let id = folder.lastPathComponent
            guard let date = date(fromDayID: id) else { continue }
            guard let values = try? folder.resourceValues(forKeys: [.isDirectoryKey]) else {
                unreadableDays.insert(id)
                continue
            }
            guard values.isDirectory == true else { continue }
            let itemsURL = folder.appending(path: "items.json")

            do {
                let data = try Data(contentsOf: itemsURL)
                let decoded = try makeDecoder().decode([ClipItem].self, from: data)
                guard !decoded.isEmpty else { continue }
                days.append(DayArchive(id: id, date: date, items: decoded))
            } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
                continue
            } catch {
                unreadableDays.insert(id)
                Logger.store.error("Failed to read day archive \(id, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
        archivedDays = days
        sortArchivedDays()
        return unreadableDays.isEmpty
    }

    private func dropArchivedItemsThatAreStillLive() {
        let liveIDs = Set(items.map(\.id))
        guard !liveIDs.isEmpty else { return }
        for index in archivedDays.indices.reversed() {
            let originalCount = archivedDays[index].items.count
            archivedDays[index].items.removeAll { liveIDs.contains($0.id) }
            guard archivedDays[index].items.count != originalCount else { continue }
            if archivedDays[index].items.isEmpty {
                let dayID = archivedDays[index].id
                archivedDays.remove(at: index)
                if !liveItemsReferenceDayFolder(dayID) {
                    removeDayFolder(dayID)
                }
            } else {
                writeDay(archivedDays[index])
            }
        }
    }

    private func merge(_ fresh: [ClipItem], intoDay id: String) -> Bool {
        guard !fresh.isEmpty else { return true }
        if let index = archivedDays.firstIndex(where: { $0.id == id }) {
            var day = archivedDays[index]
            day.items.append(contentsOf: fresh)
            guard writeDay(day) else { return false }
            archivedDays[index] = day
            return true
        }
        // An unreadable directory listing must not turn an existing archive into a new one.
        let existingURL = url(forRelative: "days/\(id)/items.json")
        if FileManager.default.fileExists(atPath: existingURL.path) {
            guard let data = try? Data(contentsOf: existingURL),
                  (try? makeDecoder().decode([ClipItem].self, from: data))?.isEmpty == true else { return false }
        }
        let archive = DayArchive(id: id, date: date(fromDayID: id) ?? fresh[0].createdAt, items: fresh)
        guard writeDay(archive) else { return false }
        archivedDays.append(archive)
        return true
    }

    @discardableResult
    private func writeDay(_ day: DayArchive) -> Bool {
        let url = url(forRelative: "days/\(day.id)/items.json")
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try makeEncoder().encode(day.items).write(to: url, options: .atomic)
            return true
        } catch {
            Logger.store.error("Failed to write day archive \(day.id, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    private func removeDayFolder(_ id: String) {
        let url = root.appending(path: "days", directoryHint: .isDirectory).appending(path: id, directoryHint: .isDirectory)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            try FileManager.default.removeItem(at: url)
        } catch {
            Logger.store.error("Failed to delete day folder \(id, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    private func queueRemovalOfSupersededFiles(_ item: ClipItem, dayID: String, removals: inout [String]) {
        guard let archived = archivedDays.first(where: { $0.id == dayID })?.items.first(where: { $0.id == item.id }) else {
            return
        }
        queueRemovalIfCopyExists(live: item.imageFileName, archived: archived.imageFileName, removals: &removals)
        queueRemovalIfCopyExists(live: item.textFileName, archived: archived.textFileName, removals: &removals)
    }

    private func queueRemovalIfCopyExists(live: String?, archived: String?, removals: inout [String]) {
        guard let live, let archived, live != archived else { return }
        if FileManager.default.fileExists(atPath: url(forRelative: archived).path) {
            removals.append(live)
        }
    }

    private func relocate(_ relative: String?, intoDay dayID: String, removals: inout [String]) -> String? {
        guard let relative else { return nil }
        guard let destination = dayRelativePath(for: relative, dayID: dayID) else { return relative }
        guard copyFile(from: relative, to: destination) else { return relative }
        if destination != relative {
            removals.append(relative)
        }
        return destination
    }

    private func relocateToLive(_ relative: String?, removals: inout [String]) -> RelocatedFile {
        guard let relative else { return RelocatedFile(path: nil, succeeded: true) }
        guard let destination = liveRelativePath(for: relative) else {
            return RelocatedFile(path: relative, succeeded: true)
        }
        guard copyFile(from: relative, to: destination) else {
            return RelocatedFile(path: relative, succeeded: false)
        }
        if destination != relative {
            removals.append(relative)
        }
        return RelocatedFile(path: destination, succeeded: true)
    }

    private func dayRelativePath(for relative: String, dayID: String) -> String? {
        let parts = relative.split(separator: "/").map(String.init)
        guard let filename = parts.last, let folder = parts.dropLast().last else { return nil }
        guard folder == "images" || folder == "texts" else { return nil }
        return "days/\(dayID)/\(folder)/\(filename)"
    }

    private func liveRelativePath(for relative: String) -> String? {
        let parts = relative.split(separator: "/").map(String.init)
        guard let filename = parts.last, let folder = parts.dropLast().last else { return nil }
        guard folder == "images" || folder == "texts" else { return nil }
        return "\(folder)/\(filename)"
    }

    private func copyFile(from relative: String, to destination: String) -> Bool {
        if relative == destination { return true }
        let sourceURL = url(forRelative: relative)
        let destinationURL = url(forRelative: destination)
        let fileManager = FileManager.default
        do {
            try fileManager.createDirectory(
                at: destinationURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            if fileManager.fileExists(atPath: destinationURL.path) {
                return true
            }
            if fileManager.fileExists(atPath: sourceURL.path) {
                try fileManager.copyItem(at: sourceURL, to: destinationURL)
                return true
            }
        } catch {
            Logger.store.error("Failed to copy archived file: \(error.localizedDescription, privacy: .public)")
        }
        return false
    }

    private func deleteUnusedSources(_ relatives: [String]) {
        let referenced = referencedFiles()
        for relative in Set(relatives) where !referenced.contains(relative) {
            try? FileManager.default.removeItem(at: url(forRelative: relative))
        }
    }

    private func liveItemsReferenceDayFolder(_ id: String) -> Bool {
        let prefix = "days/\(id)/"
        return items.contains { item in
            item.imageFileName?.hasPrefix(prefix) == true || item.textFileName?.hasPrefix(prefix) == true
        }
    }

    private func sortArchivedDays() {
        archivedDays.sort { lhs, rhs in
            if lhs.date != rhs.date { return lhs.date > rhs.date }
            return lhs.id > rhs.id
        }
    }

    private func cleanupOrphans() {
        let referenced = referencedFiles()
        removeUnreferencedFiles(in: "images", referenced: referenced)
        removeUnreferencedFiles(in: "texts", referenced: referenced)
        for day in archivedDays {
            removeUnreferencedFiles(in: "days/\(day.id)/images", referenced: referenced)
            removeUnreferencedFiles(in: "days/\(day.id)/texts", referenced: referenced)
        }
    }

    private func referencedFiles() -> Set<String> {
        var referenced = Set(items.compactMap(\.imageFileName) + items.compactMap(\.textFileName))
        for day in archivedDays {
            referenced.formUnion(day.items.compactMap(\.imageFileName))
            referenced.formUnion(day.items.compactMap(\.textFileName))
        }
        return referenced
    }

    private func removeUnreferencedFiles(in directory: String, referenced: Set<String>) {
        let url = url(forRelative: directory)
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: nil
        ) else { return }
        for file in files {
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: file.path, isDirectory: &isDirectory), isDirectory.boolValue {
                continue
            }
            let relative = "\(directory)/\(file.lastPathComponent)"
            if !referenced.contains(relative) {
                try? FileManager.default.removeItem(at: file)
            }
        }
    }

    private func observeDayChanges() {
        let token = NotificationCenter.default.addObserver(
            forName: .NSCalendarDayChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.archivePastDaysIfNeeded()
            }
        }
        dayObserver.store(token)
    }

    private var historyFileURL: URL {
        root.appending(path: "history.json")
    }

    private func encodedData() -> Data? {
        guard canSaveLiveIndex else { return nil }
        return try? makeEncoder().encode(items)
    }

    private func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .deferredToDate
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }

    private func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let value = try decoder.singleValueContainer()
            if let seconds = try? value.decode(Double.self) {
                return Date(timeIntervalSinceReferenceDate: seconds)
            }
            let legacy = try value.decode(String.self)
            guard let date = try? Date.ISO8601FormatStyle().parse(legacy) else {
                throw DecodingError.dataCorruptedError(in: value, debugDescription: "Invalid date")
            }
            return date
        }
        return decoder
    }

    private func filingCalendar() -> Calendar {
        var filing = Calendar(identifier: .gregorian)
        filing.timeZone = calendar.timeZone
        filing.locale = calendar.locale
        return filing
    }

    private func startOfDay(for date: Date) -> Date {
        filingCalendar().startOfDay(for: date)
    }

    private func dayID(for date: Date) -> String {
        let parts = filingCalendar().dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    private func date(fromDayID id: String) -> Date? {
        let pieces = id.split(separator: "-")
        guard pieces.count == 3,
              let year = Int(pieces[0]),
              let month = Int(pieces[1]),
              let day = Int(pieces[2]),
              (1...12).contains(month),
              (1...31).contains(day) else { return nil }
        var components = DateComponents()
        let filing = filingCalendar()
        components.calendar = filing
        components.timeZone = filing.timeZone
        components.year = year
        components.month = month
        components.day = day
        return filing.date(from: components)
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

private final class HistoryFileWriter: Sendable {
    static let shared = HistoryFileWriter()
    private let queue = DispatchQueue(label: "ClipboardMemory.history-writer")
    // Accessed only on queue.
    nonisolated(unsafe) private var appliedGeneration: [String: Int] = [:]

    func enqueue(data: Data, url: URL, generation: Int) {
        queue.async { self.write(data: data, url: url, generation: generation) }
    }

    func flush(data: Data, url: URL, generation: Int) -> Bool {
        queue.sync { write(data: data, url: url, generation: generation) }
    }

    @discardableResult
    private func write(data: Data, url: URL, generation: Int) -> Bool {
        let key = url.path
        guard generation >= appliedGeneration[key] ?? 0 else { return false }
        appliedGeneration[key] = generation
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            Logger.store.error("Failed to save history: \(error.localizedDescription, privacy: .public)")
            return false
        }
        // Keep a recovery copy of the committed index without duplicating attachments.
        let backup = url.appendingPathExtension("backup")
        do {
            try data.write(to: backup, options: .atomic)
        } catch {
            try? FileManager.default.removeItem(at: backup)
            Logger.store.error("Failed to update recovery index: \(error.localizedDescription, privacy: .public)")
        }
        return true
    }
}

private struct RelocatedFile {
    var path: String?
    var succeeded: Bool
}

private final class NotificationToken: @unchecked Sendable {
    private var token: NSObjectProtocol?

    func store(_ token: NSObjectProtocol) {
        self.token = token
    }

    deinit {
        if let token {
            NotificationCenter.default.removeObserver(token)
        }
    }
}

private enum Logger {
    static let store = os.Logger(subsystem: "com.belzephyrus.ClipboardMemory", category: "store")
}
