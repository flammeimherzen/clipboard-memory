import AppKit
import ImageIO
import SwiftUI

@MainActor
final class ThumbnailLoader {
    static let shared = ThumbnailLoader()
    private let cache = NSCache<NSURL, NSImage>()

    init() {
        cache.countLimit = 80
    }

    func thumbnail(for url: URL) -> NSImage? {
        let key = url as NSURL
        if let cached = cache.object(forKey: key) { return cached }
        guard let image = Self.makeThumbnail(at: url) else { return nil }
        cache.setObject(image, forKey: key)
        return image
    }

    private static func makeThumbnail(at url: URL) -> NSImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 128
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    }
}

struct Thumbnail: View {
    let url: URL
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: "photo")
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 36, height: 36)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 4))
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .task(id: url) {
            image = ThumbnailLoader.shared.thumbnail(for: url)
        }
    }
}
