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
}

@MainActor
private struct TestStore {
    let store: HistoryStore
    let root: URL
    let defaults: UserDefaults
    let suite: String

    init(limit: Int = 200) {
        suite = "ClipboardMemoryTests.\(UUID().uuidString)"
        root = FileManager.default.temporaryDirectory
            .appending(path: "ClipboardMemoryTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defaults.set(limit, forKey: "historyLimit")
        self.defaults = defaults
        store = HistoryStore(root: root, defaults: defaults)
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
        UserDefaults.standard.removePersistentDomain(forName: suite)
    }
}
