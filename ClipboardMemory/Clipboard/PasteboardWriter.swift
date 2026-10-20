import AppKit

@MainActor
enum PasteboardWriter {
    static func write(_ item: ClipItem, using store: HistoryStore, pasteboard: NSPasteboard = .general) -> Int? {
        switch item.kind {
        case .text:
            guard let text = store.text(for: item) else { return nil }
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)
        case .image:
            guard let data = store.imageData(for: item) else { return nil }
            let pasteboardItem = NSPasteboardItem()
            let fileExtension = item.imageFileName.map { URL(fileURLWithPath: $0).pathExtension.lowercased() }
            if fileExtension == "jpg" || fileExtension == "jpeg" {
                pasteboardItem.setData(data, forType: NSPasteboard.PasteboardType("public.jpeg"))
                if let png = ImageTranscoder.pngData(from: data)?.0 {
                    pasteboardItem.setData(png, forType: .png)
                }
            } else {
                pasteboardItem.setData(data, forType: .png)
            }
            if let tiff = ImageTranscoder.tiffData(from: data) {
                pasteboardItem.setData(tiff, forType: .tiff)
            }
            pasteboard.clearContents()
            guard pasteboard.writeObjects([pasteboardItem]) else { return nil }
        }
        return pasteboard.changeCount
    }
}
