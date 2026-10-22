import AppKit
import SwiftUI

struct ClipRow: View {
    let item: ClipItem
    let store: HistoryStore
    var showsExactTime = false

    var body: some View {
        HStack(spacing: 8) {
            leading
            VStack(alignment: .leading, spacing: 2) {
                Text(ClipFormatting.title(for: item, store: store))
                    .lineLimit(1)
                HStack(spacing: 4) {
                    if item.kind == .image {
                        Image(nsImage: AppIconProvider.shared.icon(for: item.sourceAppBundleID))
                            .resizable()
                            .frame(width: 12, height: 12)
                    }
                    Text(ClipFormatting.subtitle(for: item, exactTime: showsExactTime))
                        .lineLimit(1)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 4)
            if item.isPinned {
                Image(systemName: "pin.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private var leading: some View {
        if item.kind == .image, let name = item.imageFileName {
            Thumbnail(url: store.url(forRelative: name))
        } else {
            Image(nsImage: AppIconProvider.shared.icon(for: item.sourceAppBundleID))
                .resizable()
                .frame(width: 28, height: 28)
        }
    }
}

@MainActor
final class AppIconProvider {
    static let shared = AppIconProvider()
    private var cache: [String: NSImage] = [:]

    func icon(for bundleID: String?) -> NSImage {
        guard let bundleID else { return fallback }
        if let cached = cache[bundleID] { return cached }
        let image: NSImage
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            let icon = NSWorkspace.shared.icon(forFile: url.path)
            image = (icon.copy() as? NSImage) ?? icon
        } else {
            image = fallback
        }
        image.size = NSSize(width: 28, height: 28)
        cache[bundleID] = image
        return image
    }

    private var fallback: NSImage {
        let image = NSImage(named: NSImage.applicationIconName) ?? NSImage()
        image.size = NSSize(width: 28, height: 28)
        return image
    }
}
