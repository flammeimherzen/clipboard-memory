import AppKit
import SwiftUI

struct PreviewPane: View {
    let item: ClipItem?
    let store: HistoryStore

    var body: some View {
        Group {
            if let item {
                switch item.kind {
                case .text:
                    ScrollView {
                        Text(store.text(for: item) ?? "")
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                            .padding(12)
                    }
                case .image:
                    if let name = item.imageFileName {
                        FullImage(url: store.url(forRelative: name))
                    } else {
                        missing
                    }
                }
            } else {
                missing
            }
        }
    }

    private var missing: some View {
        Text("Nothing selected")
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct FullImage: View {
    let url: URL
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .padding(12)
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: url) {
            image = NSImage(contentsOf: url)
        }
    }
}
