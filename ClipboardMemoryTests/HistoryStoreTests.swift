import Foundation
import Testing
@testable import ClipboardMemory

@MainActor
struct HistoryStoreTests {
    @Test func deduplicatesTextAndPromotesIt() {
        let fixture = TestStore()
        defer { fixture.cleanup() }
        fixture.store.addText("alpha", source: nil)
        let firstDate = fixture.store.items[0].lastUsedAt
        Thread.sleep(forTimeInterval: 0.02)
        fixture.store.addText("beta", source: nil)
        fixture.store.addText("alpha", source: SourceApp(bundleID: "com.example.app", name: "Example"))

        #expect(fixture.store.items.count == 2)
        let alpha = fixture.store.items.first { fixture.store.text(for: $0) == "alpha" }
        #expect(alpha?.lastUsedAt ?? firstDate > firstDate)
        #expect(alpha?.sourceAppName == "Example")
        #expect(fixture.store.text(for: fixture.store.sortedItems[0]) == "alpha")
    }

    @Test func limitKeepsPinnedItemsAndStillAcceptsNewCopies() {
        let fixture = TestStore(limit: 1)
        defer { fixture.cleanup() }
        fixture.store.addText("a", source: nil)
        let pinnedID = fixture.store.items[0].id
        fixture.store.togglePin(id: pinnedID)
        fixture.store.addText("b", source: nil)
        let secondPin = fixture.store.items.first { fixture.store.text(for: $0) == "b" }!.id
        fixture.store.togglePin(id: secondPin)
        fixture.store.addText("c", source: nil)
        let thirdPin = fixture.store.items.first { fixture.store.text(for: $0) == "c" }!.id
        fixture.store.togglePin(id: thirdPin)
        fixture.store.addText("d", source: nil)
        fixture.store.addText("e", source: nil)

        #expect(fixture.store.items.filter(\.isPinned).count == 3)
        #expect(fixture.store.unpinnedCount == 1)
        #expect(fixture.store.text(for: fixture.store.items.first { !$0.isPinned }!) == "e")
        #expect(fixture.store.items.contains { $0.id == pinnedID })
    }

    @Test func deletingImageRemovesItsFile() {
        let fixture = TestStore()
        defer { fixture.cleanup() }
        fixture.store.addImage(data: Data("image-body".utf8), fileExtension: "png", source: nil)
        let item = fixture.store.items[0]
        let url = fixture.store.url(forRelative: item.imageFileName!)

        #expect(FileManager.default.fileExists(atPath: url.path))
        fixture.store.delete(id: item.id)
        #expect(fixture.store.items.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test func trimmingDeletesTheOldestImageFile() {
        let fixture = TestStore(limit: 1)
        defer { fixture.cleanup() }
        fixture.store.addImage(data: Data("one".utf8), fileExtension: "png", source: nil)
        let firstURL = fixture.store.url(forRelative: fixture.store.items[0].imageFileName!)
        fixture.store.addImage(data: Data("two".utf8), fileExtension: "png", source: nil)

        #expect(fixture.store.items.count == 1)
        #expect(fixture.store.imageData(for: fixture.store.items[0]) == Data("two".utf8))
        #expect(!FileManager.default.fileExists(atPath: firstURL.path))
    }

    @Test func longTextGoesToSidecarAndReloads() {
        let fixture = TestStore()
        defer { fixture.cleanup() }
        let text = String(repeating: "я", count: 40_000)
        fixture.store.addText(text, source: nil)
        let item = fixture.store.items[0]

        #expect(item.text == nil)
        #expect(item.textFileName != nil)
        #expect(fixture.store.text(for: item) == text)
        fixture.store.flush()

        let reloaded = HistoryStore(root: fixture.root, defaults: fixture.defaults)
        #expect(reloaded.items.count == 1)
        #expect(reloaded.text(for: reloaded.items[0]) == text)
    }

    @Test func shortTextStaysInline() {
        let fixture = TestStore()
        defer { fixture.cleanup() }
        fixture.store.addText("короткий", source: nil)
        #expect(fixture.store.items[0].text == "короткий")
        #expect(fixture.store.items[0].textFileName == nil)
    }

    @Test func rejectsOversizedText() {
        let fixture = TestStore()
        defer { fixture.cleanup() }
        let text = String(repeating: "a", count: HistoryStore.maxTextBytes + 1)
        fixture.store.addText(text, source: nil)
        #expect(fixture.store.items.isEmpty)
    }

    @Test func corruptHistoryStartsEmptyAndKeepsTheBrokenFile() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "ClipboardMemoryTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("{{{".utf8).write(to: root.appending(path: "history.json"))
        let suite = "ClipboardMemoryTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer {
            try? FileManager.default.removeItem(at: root)
            UserDefaults.standard.removePersistentDomain(forName: suite)
        }

        let store = HistoryStore(root: root, defaults: defaults)
        #expect(store.items.isEmpty)
        let broken = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("history.json.broken-") }
        #expect(broken.count == 1)
    }

    @Test func saveAndReloadRoundTrip() {
        let fixture = TestStore()
        defer { fixture.cleanup() }
        fixture.store.addText("hello", source: SourceApp(bundleID: "com.apple.TextEdit", name: "TextEdit"))
        fixture.store.flush()

        let reloaded = HistoryStore(root: fixture.root, defaults: fixture.defaults)
        #expect(reloaded.items.count == 1)
        #expect(reloaded.text(for: reloaded.items[0]) == "hello")
        #expect(reloaded.items[0].sourceAppName == "TextEdit")
    }

    @Test func removesOrphanFilesOnLoad() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "ClipboardMemoryTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        let images = root.appending(path: "images", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: images, withIntermediateDirectories: true)
        let orphan = images.appending(path: "orphan.png")
        try Data("x".utf8).write(to: orphan)
        let suite = "ClipboardMemoryTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer {
            try? FileManager.default.removeItem(at: root)
            UserDefaults.standard.removePersistentDomain(forName: suite)
        }

        _ = HistoryStore(root: root, defaults: defaults)
        #expect(!FileManager.default.fileExists(atPath: orphan.path))
    }

    @Test func clearUnpinnedKeepsPinnedRecords() {
        let fixture = TestStore()
        defer { fixture.cleanup() }
        fixture.store.addText("keep", source: nil)
        fixture.store.togglePin(id: fixture.store.items[0].id)
        fixture.store.addText("drop", source: nil)
        fixture.store.clearUnpinned()

        #expect(fixture.store.items.count == 1)
        #expect(fixture.store.text(for: fixture.store.items[0]) == "keep")
    }

    @Test func imageCopiesWithTheSameBytesCollapse() {
        let fixture = TestStore()
        defer { fixture.cleanup() }
        let data = Data("same-bytes".utf8)
        fixture.store.addImage(data: data, fileExtension: "png", source: nil)
        fixture.store.addImage(data: data, fileExtension: "png", source: nil)
        #expect(fixture.store.items.count == 1)
    }

    @Test func searchAndFilterUseVisibleItems() {
        let fixture = TestStore()
        defer { fixture.cleanup() }
        fixture.store.addText("Альфа", source: nil)
        fixture.store.addImage(
            data: Data("img".utf8),
            fileExtension: "png",
            source: SourceApp(bundleID: nil, name: "Preview")
        )
        let session = HistorySession()

        #expect(session.visibleItems(in: fixture.store).count == 2)
        session.query = "аль"
        #expect(session.visibleItems(in: fixture.store).map { fixture.store.text(for: $0) } == ["Альфа"])
        session.query = ""
        session.filter = .image
        #expect(session.visibleItems(in: fixture.store).count == 1)
        session.query = "preview"
        #expect(session.visibleItems(in: fixture.store).first?.kind == .image)
    }

    @Test func archivesUnpinnedItemsWhenTheDayChanges() {
        let calendar = utcCalendar()
        let clock = ManualClock(date(2026, 10, 21, 15, calendar: calendar))
        let fixture = TestStore(calendar: calendar, now: { clock.date })
        defer { fixture.cleanup() }

        fixture.store.addText("yesterday", source: nil)
        clock.date = date(2026, 10, 22, 9, calendar: calendar)
        fixture.store.addText("today", source: nil)

        #expect(texts(in: fixture.store.items, store: fixture.store) == ["today"])
        #expect(fixture.store.archivedDays.map(\.id) == ["2026-10-21"])
        #expect(texts(in: fixture.store.archivedDays[0].items, store: fixture.store) == ["yesterday"])
        #expect(fixture.store.currentDayID == "2026-10-22")
    }

    @Test func keepsPinnedItemsInTheCurrentDay() {
        let calendar = utcCalendar()
        let clock = ManualClock(date(2026, 10, 20, 12, calendar: calendar))
        let fixture = TestStore(calendar: calendar, now: { clock.date })
        defer { fixture.cleanup() }

        fixture.store.addText("keep", source: nil)
        let pinnedID = fixture.store.items[0].id
        fixture.store.togglePin(id: pinnedID)
        fixture.store.addText("drop", source: nil)
        clock.date = date(2026, 10, 22, 12, calendar: calendar)
        fixture.store.archivePastDaysIfNeeded()

        #expect(texts(in: fixture.store.items, store: fixture.store) == ["keep"])
        #expect(fixture.store.items[0].isPinned)
        #expect(texts(in: fixture.store.archivedDays[0].items, store: fixture.store) == ["drop"])
        #expect(fixture.store.archivedDays[0].id == "2026-10-20")

        fixture.store.togglePin(id: pinnedID)
        #expect(fixture.store.items.isEmpty)
        #expect(texts(in: fixture.store.archivedDays[0].items, store: fixture.store) == ["keep", "drop"])
    }

    @Test func movesImageAndTextFilesIntoTheDayFolder() throws {
        let calendar = utcCalendar()
        let clock = ManualClock(date(2026, 10, 21, 16, calendar: calendar))
        let fixture = TestStore(calendar: calendar, now: { clock.date })
        defer { fixture.cleanup() }

        let image = Data("image-body".utf8)
        fixture.store.addImage(data: image, fileExtension: "png", source: nil)
        let longText = String(repeating: "я", count: 40_000)
        fixture.store.addText(longText, source: nil)
        let oldImage = fixture.store.items.first { $0.kind == .image }!.imageFileName!
        let oldText = fixture.store.items.first { $0.kind == .text }!.textFileName!
        clock.date = date(2026, 10, 22, 8, calendar: calendar)
        fixture.store.archivePastDaysIfNeeded()

        let day = try #require(fixture.store.archivedDays.first)
        let archivedImage = try #require(day.items.first { $0.kind == .image })
        let archivedText = try #require(day.items.first { $0.kind == .text })
        #expect(archivedImage.imageFileName?.hasPrefix("days/2026-10-21/images/") == true)
        #expect(archivedText.textFileName?.hasPrefix("days/2026-10-21/texts/") == true)
        #expect(fixture.store.imageData(for: archivedImage) == image)
        #expect(fixture.store.text(for: archivedText) == longText)
        #expect(!FileManager.default.fileExists(atPath: fixture.store.url(forRelative: oldImage).path))
        #expect(!FileManager.default.fileExists(atPath: fixture.store.url(forRelative: oldText).path))
        let dayFolder = fixture.root.appending(path: "days").appending(path: "2026-10-21")
        #expect(FileManager.default.fileExists(atPath: dayFolder.appending(path: "items.json").path))

        let orphan = dayFolder.appending(path: "images").appending(path: "orphan.png")
        try Data("z".utf8).write(to: orphan)
        let reloaded = HistoryStore(root: fixture.root, defaults: fixture.defaults, calendar: calendar, now: { clock.date })
        let reloadedImage = try #require(reloaded.archivedDays.first?.items.first { $0.kind == .image })
        #expect(reloaded.imageData(for: reloadedImage) == image)
        #expect(reloaded.text(for: try #require(reloaded.archivedDays[0].items.first { $0.kind == .text })) == longText)
        #expect(!FileManager.default.fileExists(atPath: orphan.path))
    }

    @Test func pinningArchivedItemReturnsItToToday() throws {
        let calendar = utcCalendar()
        let clock = ManualClock(date(2026, 10, 21, 11, calendar: calendar))
        let fixture = TestStore(calendar: calendar, now: { clock.date })
        defer { fixture.cleanup() }

        fixture.store.addImage(data: Data("picture".utf8), fileExtension: "png", source: nil)
        fixture.store.addText(String(repeating: "t", count: 40_000), source: nil)
        clock.date = date(2026, 10, 22, 11, calendar: calendar)
        fixture.store.archivePastDaysIfNeeded()
        let image = try #require(fixture.store.archivedDays[0].items.first { $0.kind == .image })
        fixture.store.togglePin(id: image.id)

        let restored = try #require(fixture.store.items.first { $0.id == image.id })
        #expect(restored.isPinned)
        #expect(restored.imageFileName?.hasPrefix("images/") == true)
        #expect(FileManager.default.fileExists(atPath: fixture.store.url(forRelative: restored.imageFileName!).path))
        let day = try #require(fixture.store.archivedDays.first)
        #expect(day.items.count == 1)
        #expect(day.items[0].kind == .text)
        #expect(day.items[0].textFileName?.hasPrefix("days/2026-10-21/texts/") == true)
        #expect(FileManager.default.fileExists(atPath: fixture.store.url(forRelative: day.items[0].textFileName!).path))
    }

    @Test func deleteDayRemovesTheFolder() {
        let calendar = utcCalendar()
        let clock = ManualClock(date(2026, 10, 19, 10, calendar: calendar))
        let fixture = TestStore(calendar: calendar, now: { clock.date })
        defer { fixture.cleanup() }

        fixture.store.addText("gone", source: nil)
        clock.date = date(2026, 10, 22, 10, calendar: calendar)
        fixture.store.archivePastDaysIfNeeded()
        let dayID = fixture.store.archivedDays[0].id
        fixture.store.deleteDay(id: dayID)

        #expect(fixture.store.archivedDays.isEmpty)
        let dayFolder = fixture.root.appending(path: "days").appending(path: dayID)
        #expect(!FileManager.default.fileExists(atPath: dayFolder.path))
    }

    @Test func visibleItemsCanBrowseAPastDay() {
        let calendar = utcCalendar()
        let clock = ManualClock(date(2026, 10, 21, 18, calendar: calendar))
        let fixture = TestStore(calendar: calendar, now: { clock.date })
        defer { fixture.cleanup() }

        fixture.store.addText("yesterday", source: nil)
        clock.date = date(2026, 10, 22, 18, calendar: calendar)
        fixture.store.addText("today", source: nil)
        let session = HistorySession()
        let dayID = fixture.store.archivedDays[0].id

        session.openDay(dayID, in: fixture.store)
        #expect(session.visibleItems(in: fixture.store).map { fixture.store.text(for: $0) } == ["yesterday"])
        session.query = "nope"
        #expect(session.visibleItems(in: fixture.store).isEmpty)
        session.showToday(in: fixture.store)
        #expect(session.query.isEmpty)
        #expect(session.visibleItems(in: fixture.store).map { fixture.store.text(for: $0) } == ["today"])
    }

    @Test func clearUnpinnedKeepsDayFolders() {
        let calendar = utcCalendar()
        let clock = ManualClock(date(2026, 10, 21, 12, calendar: calendar))
        let fixture = TestStore(calendar: calendar, now: { clock.date })
        defer { fixture.cleanup() }

        fixture.store.addText("archived", source: nil)
        clock.date = date(2026, 10, 22, 12, calendar: calendar)
        fixture.store.addText("fresh", source: nil)
        fixture.store.clearUnpinned()

        #expect(fixture.store.items.isEmpty)
        #expect(texts(in: fixture.store.archivedDays[0].items, store: fixture.store) == ["archived"])
    }

    @Test func recopyingAnArchivedClipStartsANewDay() {
        let calendar = utcCalendar()
        let clock = ManualClock(date(2026, 10, 21, 12, calendar: calendar))
        let fixture = TestStore(calendar: calendar, now: { clock.date })
        defer { fixture.cleanup() }

        fixture.store.addText("same", source: nil)
        clock.date = date(2026, 10, 22, 12, calendar: calendar)
        fixture.store.addText("same", source: SourceApp(bundleID: "com.example.app", name: "Example"))

        #expect(fixture.store.items.count == 1)
        #expect(fixture.store.archivedDays.count == 1)
        #expect(fixture.store.items[0].id != fixture.store.archivedDays[0].items[0].id)
        #expect(fixture.store.text(for: fixture.store.items[0]) == "same")
        #expect(fixture.store.text(for: fixture.store.archivedDays[0].items[0]) == "same")
        #expect(fixture.store.items[0].sourceAppName == "Example")
    }

    @Test func itemCopiedJustBeforeMidnightArchivesOnTheNextDay() {
        let calendar = utcCalendar()
        let clock = ManualClock(date(2026, 10, 21, 23, 30, calendar: calendar))
        let fixture = TestStore(calendar: calendar, now: { clock.date })
        defer { fixture.cleanup() }

        fixture.store.addText("late", source: nil)
        clock.date = date(2026, 10, 22, 0, 30, calendar: calendar)
        fixture.store.archivePastDaysIfNeeded()

        #expect(fixture.store.items.isEmpty)
        #expect(fixture.store.archivedDays.map(\.id) == ["2026-10-21"])
        #expect(fixture.store.currentDayID == "2026-10-22")
    }
}

private func utcCalendar() -> Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    calendar.locale = Locale(identifier: "en_US_POSIX")
    return calendar
}

private func date(
    _ year: Int,
    _ month: Int,
    _ day: Int,
    _ hour: Int,
    _ minute: Int = 0,
    calendar: Calendar
) -> Date {
    var components = DateComponents()
    components.calendar = calendar
    components.timeZone = calendar.timeZone
    components.year = year
    components.month = month
    components.day = day
    components.hour = hour
    components.minute = minute
    return calendar.date(from: components)!
}

@MainActor
private func texts(in items: [ClipItem], store: HistoryStore) -> Set<String> {
    Set(items.compactMap { store.text(for: $0) })
}

@MainActor
private final class ManualClock {
    var date: Date
    init(_ date: Date) { self.date = date }
}

@MainActor
private struct TestStore {
    let store: HistoryStore
    let root: URL
    let defaults: UserDefaults
    let suite: String
    let calendar: Calendar

    init(
        limit: Int = 200,
        calendar: Calendar = .current,
        now: @escaping @MainActor () -> Date = { Date() }
    ) {
        suite = "ClipboardMemoryTests.\(UUID().uuidString)"
        root = FileManager.default.temporaryDirectory
            .appending(path: "ClipboardMemoryTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defaults.set(limit, forKey: "historyLimit")
        self.defaults = defaults
        self.calendar = calendar
        store = HistoryStore(root: root, defaults: defaults, calendar: calendar, now: now)
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
        UserDefaults.standard.removePersistentDomain(forName: suite)
    }
}
