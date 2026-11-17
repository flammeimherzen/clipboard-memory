import AppKit

@MainActor
enum PasteboardWriter {
    static func write(_ item: ClipItem, using store: HistoryStore, pasteboard: NSPasteboard = .general) -> Int? {
        switch item.kind {
        case .text:
            guard let text = store.text(for: item) else { return nil }
            pasteboard.clearContents()
            guard pasteboard.setString(text, forType: .string) else { return nil }
        case .image:
            guard let data = store.imageData(for: item) else { return nil }
            let pasteboardItem = NSPasteboardItem()
            let fileExtension = item.imageFileName.map { URL(fileURLWithPath: $0).pathExtension.lowercased() }
            let isJPEG = fileExtension == "jpg" || fileExtension == "jpeg"
            let originalType = isJPEG ? NSPasteboard.PasteboardType("public.jpeg") : .png
            guard pasteboardItem.setData(data, forType: originalType),
                  pasteboardItem.setDataProvider(ImageDataProvider(data), forTypes: isJPEG ? [.png, .tiff] : [.tiff])
            else { return nil }
            pasteboard.clearContents()
            guard pasteboard.writeObjects([pasteboardItem]) else { return nil }
        }
        return pasteboard.changeCount
    }
}

private final class ImageDataProvider: NSObject, NSPasteboardItemDataProvider {
    // Keep the original bytes available even if history is cleared before paste.
    private let original: Data

    init(_ original: Data) {
        self.original = original
    }

    func pasteboard(_ pasteboard: NSPasteboard?, item: NSPasteboardItem, provideDataForType type: NSPasteboard.PasteboardType) {
        let data = type == .tiff ? ImageTranscoder.tiffData(from: original) : ImageTranscoder.pngData(from: original)?.0
        if let data { item.setData(data, forType: type) }
    }
}
