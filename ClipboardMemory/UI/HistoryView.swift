import AppKit
import SwiftUI

enum ClipFilter: String, CaseIterable, Identifiable {
    case all
    case text
    case image

    var id: String { rawValue }
}

@MainActor
@Observable
final class HistorySession {
    var query = ""
    var filter: ClipFilter = .all
    var selection: UUID?
    weak var searchField: NSSearchField?

    func reset(in store: HistoryStore) {
        query = ""
        filter = .all
        searchField?.stringValue = ""
        selection = visibleItems(in: store).first?.id
    }

    func visibleItems(in store: HistoryStore) -> [ClipItem] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return store.sortedItems.filter { item in
            switch filter {
            case .all:
                break
            case .text:
                if item.kind != .text { return false }
            case .image:
                if item.kind != .image { return false }
            }
            guard !needle.isEmpty else { return true }
            switch item.kind {
            case .text:
                return (store.text(for: item) ?? "").lowercased().contains(needle)
            case .image:
                let caption = ClipFormatting.title(for: item, store: store).lowercased()
                let appName = (item.sourceAppName ?? "").lowercased()
                return caption.contains(needle) || appName.contains(needle)
            }
        }
    }
}

@MainActor
enum ClipFormatting {
    private static let relative: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: "en_US")
        formatter.unitsStyle = .short
        return formatter
    }()

    static func title(for item: ClipItem, store: HistoryStore) -> String {
        switch item.kind {
        case .text:
            let text = store.text(for: item) ?? ""
            let line = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
            return line.isEmpty ? "Text" : line
        case .image:
            guard let size = item.pixelSize else { return "Image" }
            return "Image \(Int(size.width))×\(Int(size.height))"
        }
    }

    static func subtitle(for item: ClipItem) -> String {
        let time = relative.localizedString(for: item.lastUsedAt, relativeTo: Date())
        guard let name = item.sourceAppName, !name.isEmpty else { return time }
        return "\(name) · \(time)"
    }
}

enum HistoryChrome {
    case material
    case notch
}

struct HistoryView: View {
    @Bindable var store: HistoryStore
    @Bindable var session: HistorySession
    var monitor: ClipboardMonitor
    var chrome: HistoryChrome = .material
    var onCommit: (ClipItem) -> Void
    var onOpenSettings: () -> Void
    var onQuit: () -> Void

    @State private var confirmClear = false

    var body: some View {
        let visible = session.visibleItems(in: store)
        VStack(spacing: 10) {
            SearchField(text: session.query, dark: chrome == .notch) { newValue in
                session.query = newValue
                session.selection = session.visibleItems(in: store).first?.id
            } onReady: { field in
                session.searchField = field
            }

            if let notice = monitor.accessNotice {
                AccessBanner(message: notice.message)
            }

            HStack(spacing: 0) {
                list(visible)
                Divider()
                PreviewPane(
                    item: visible.first { $0.id == session.selection } ?? visible.first,
                    store: store
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(maxHeight: .infinity)
            .background(
                chrome == .notch ? Color.white.opacity(0.06) : Color(nsColor: .windowBackgroundColor).opacity(0.35),
                in: RoundedRectangle(cornerRadius: chrome == .notch ? 20 : 10, style: .continuous)
            )
            .clipShape(RoundedRectangle(cornerRadius: chrome == .notch ? 20 : 10, style: .continuous))

            footer(visibleCount: visible.count)
        }
        .padding(chrome == .notch ? 14 : 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            if chrome == .notch {
                NotchBlack.swiftUI
            } else {
                Rectangle().fill(.regularMaterial)
            }
        }
        .alert("Clear history?", isPresented: $confirmClear) {
            Button("Delete", role: .destructive) {
                store.clearUnpinned()
                session.selection = session.visibleItems(in: store).first?.id
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This deletes \(store.unpinnedCount) unpinned items. Pinned items stay.")
        }
    }

    private func list(_ visible: [ClipItem]) -> some View {
        Group {
            if store.items.isEmpty {
                emptyState(
                    title: "Nothing yet",
                    text: "Copy text or an image and it will show up here."
                )
            } else if visible.isEmpty {
                emptyState(title: "No matches", text: "Try a different search.")
            } else {
                List(selection: $session.selection) {
                    ForEach(visible) { item in
                        Button {
                            onCommit(item)
                        } label: {
                            ClipRow(item: item, store: store)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.plain)
                        .tag(item.id)
                        .listRowInsets(EdgeInsets(top: 2, leading: 8, bottom: 2, trailing: 8))
                        .listRowBackground(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(item.id == session.selection ? Color.accentColor.opacity(0.35) : Color.clear)
                        )
                        .contextMenu {
                            Button(item.isPinned ? "Unpin" : "Pin") {
                                store.togglePin(id: item.id)
                            }
                            Button("Delete", role: .destructive) {
                                store.delete(id: item.id)
                            }
                        }
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(chrome == .notch ? .hidden : .automatic)
            }
        }
        .frame(width: 340)
    }

    private func emptyState(title: String, text: String) -> some View {
        VStack(spacing: 6) {
            Text(title).font(.headline)
            Text(text)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func footer(visibleCount: Int) -> some View {
        HStack(spacing: 8) {
            Button(store.isPaused ? "Resume" : "Pause") {
                store.isPaused.toggle()
            }
            Button("Clear") { confirmClear = true }
                .disabled(store.unpinnedCount == 0)
            Text("\(visibleCount)")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Text("⌘1–9 · ⌘P · ⌘⌫")
                .font(.caption)
                .foregroundStyle(.tertiary)
            Button("Settings") { onOpenSettings() }
            Button("Quit") { onQuit() }
        }
        .buttonBorderShape(chrome == .notch ? .capsule : .automatic)
    }
}

private struct AccessBanner: View {
    let message: String

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(message)
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button("Open Settings") {
                SystemSettings.openPasteboardPrivacy()
            }
        }
        .padding(8)
        .background(.yellow.opacity(0.16), in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct SearchField: NSViewRepresentable {
    var text: String
    var dark: Bool
    var onTextChange: (String) -> Void
    var onReady: (NSSearchField) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onTextChange: onTextChange)
    }

    func makeNSView(context: Context) -> NSSearchField {
        let field = NSSearchField(frame: .zero)
        field.placeholderString = "Search"
        field.delegate = context.coordinator
        style(field)
        context.coordinator.onTextChange = onTextChange
        field.sendsSearchStringImmediately = true
        context.coordinator.onTextChange = onTextChange
        DispatchQueue.main.async {
            onReady(field)
        }
        return field
    }

    func updateNSView(_ nsView: NSSearchField, context: Context) {
        context.coordinator.onTextChange = onTextChange
        style(nsView)
        if nsView.stringValue != text {
            nsView.stringValue = text
        }
    }

    private func style(_ field: NSSearchField) {
        field.focusRingType = .none
        field.wantsLayer = true
        field.layer?.cornerRadius = 14
        field.layer?.masksToBounds = true
        if dark {
            field.appearance = NSAppearance(named: .darkAqua)
        }
    }

    final class Coordinator: NSObject, NSSearchFieldDelegate {
        var onTextChange: (String) -> Void

        init(onTextChange: @escaping (String) -> Void) {
            self.onTextChange = onTextChange
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSSearchField else { return }
            let value = field.stringValue
            let callback = onTextChange
            Task { @MainActor in
                callback(value)
            }
        }
    }
}
