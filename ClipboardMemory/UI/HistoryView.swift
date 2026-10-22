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
    var selectedDayID: String?
    weak var searchField: NSSearchField?

    func reset(in store: HistoryStore) {
        store.archivePastDaysIfNeeded()
        showToday(in: store)
    }

    func openDay(_ id: String, in store: HistoryStore) {
        selectedDayID = id
        query = ""
        filter = .all
        searchField?.stringValue = ""
        selection = visibleItems(in: store).first?.id
    }

    func showToday(in store: HistoryStore) {
        selectedDayID = nil
        query = ""
        filter = .all
        searchField?.stringValue = ""
        selection = visibleItems(in: store).first?.id
    }

    func visibleItems(in store: HistoryStore) -> [ClipItem] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return baseItems(in: store).filter { item in
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

    private func baseItems(in store: HistoryStore) -> [ClipItem] {
        if let selectedDayID,
           let day = store.archivedDays.first(where: { $0.id == selectedDayID }) {
            return day.items.sorted { lhs, rhs in
                if lhs.createdAt != rhs.createdAt { return lhs.createdAt > rhs.createdAt }
                return lhs.id.uuidString > rhs.id.uuidString
            }
        }
        return store.sortedItems
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

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US")
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter
    }()

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US")
        formatter.dateStyle = .none
        formatter.timeStyle = .short
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

    static func subtitle(for item: ClipItem, exactTime: Bool = false) -> String {
        let time = exactTime
            ? timeFormatter.string(from: item.createdAt)
            : relative.localizedString(for: item.lastUsedAt, relativeTo: Date())
        guard let name = item.sourceAppName, !name.isEmpty else { return time }
        return "\(name) · \(time)"
    }

    static func todayTitle(for date: Date) -> String {
        "Today · \(dayTitle(for: date))"
    }

    static func dayTitle(for date: Date) -> String {
        dayFormatter.string(from: date)
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
    @State private var confirmDeleteDay = false
    @State private var dayPendingDelete: String?

    private var pastDay: DayArchive? {
        store.archivedDays.first { $0.id == session.selectedDayID }
    }

    private var todayHeading: String {
        _ = store.currentDayID
        return ClipFormatting.todayTitle(for: store.currentDate)
    }

    var body: some View {
        let visible = session.visibleItems(in: store)
        VStack(spacing: 10) {
            dayBar
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
                if !store.archivedDays.isEmpty {
                    Divider()
                    dayColumn
                }
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
            Text("This deletes \(store.unpinnedCount) unpinned items from today. Pinned items and earlier days stay.")
        }
        .alert("Delete this day?", isPresented: $confirmDeleteDay) {
            Button("Delete", role: .destructive) {
                if let id = dayPendingDelete {
                    store.deleteDay(id: id)
                    if session.selectedDayID == id {
                        session.showToday(in: store)
                    }
                }
                dayPendingDelete = nil
            }
            Button("Cancel", role: .cancel) {
                dayPendingDelete = nil
            }
        } message: {
            Text("This deletes the folder and everything copied that day.")
        }
    }

    private var dayBar: some View {
        HStack(spacing: 8) {
            if let pastDay {
                Button {
                    session.showToday(in: store)
                } label: {
                    Label("Today", systemImage: "chevron.backward")
                }
                .help("Back to today")
                Text(ClipFormatting.dayTitle(for: pastDay.date))
                    .font(.headline)
                    .lineLimit(1)
                Text(itemCount(pastDay.items.count))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Button(role: .destructive) {
                    dayPendingDelete = pastDay.id
                    confirmDeleteDay = true
                } label: {
                    Image(systemName: "trash")
                }
                .help("Delete this day")
            } else {
                Image(systemName: "calendar")
                    .foregroundStyle(.secondary)
                Text(todayHeading)
                    .font(.headline)
                    .lineLimit(1)
                Spacer(minLength: 8)
            }
        }
        .buttonStyle(.borderless)
    }

    private var dayColumn: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                Text("Days")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.bottom, 4)
                dayButton(
                    title: "Today",
                    subtitle: itemCount(store.items.count),
                    systemImage: "calendar",
                    tint: .secondary,
                    isSelected: pastDay == nil
                ) {
                    guard session.selectedDayID != nil else { return }
                    session.showToday(in: store)
                }
                ForEach(store.archivedDays) { day in
                    dayButton(
                        title: ClipFormatting.dayTitle(for: day.date),
                        subtitle: itemCount(day.items.count),
                        systemImage: "folder.fill",
                        tint: .yellow,
                        isSelected: day.id == session.selectedDayID
                    ) {
                        guard session.selectedDayID != day.id else { return }
                        session.openDay(day.id, in: store)
                    }
                    .contextMenu {
                        Button("Delete Day", role: .destructive) {
                            dayPendingDelete = day.id
                            confirmDeleteDay = true
                        }
                    }
                }
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(width: 176)
    }

    private func dayButton(
        title: String,
        subtitle: String,
        systemImage: String,
        tint: Color,
        isSelected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: systemImage)
                    .foregroundStyle(tint)
                    .frame(width: 16)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .lineLimit(1)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
        }
        .buttonStyle(DayRowButtonStyle(isSelected: isSelected))
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityLabel("\(title), \(subtitle)")
    }

    private func list(_ visible: [ClipItem]) -> some View {
        Group {
            if visible.isEmpty {
                emptyState(
                    title: emptyTitle,
                    text: emptyMessage
                )
            } else {
                List(selection: $session.selection) {
                    ForEach(visible) { item in
                        clipButton(item)
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(chrome == .notch ? .hidden : .automatic)
            }
        }
        .frame(width: 340)
    }

    private var emptyTitle: String {
        if !session.query.isEmpty || session.filter != .all {
            return "No matches"
        }
        if pastDay == nil && store.items.isEmpty && !store.archivedDays.isEmpty {
            return "Nothing copied today"
        }
        if store.items.isEmpty && store.archivedDays.isEmpty {
            return "Nothing yet"
        }
        return "No matches"
    }

    private var emptyMessage: String {
        if !session.query.isEmpty || session.filter != .all {
            return "Try a different search."
        }
        if pastDay == nil && store.items.isEmpty && !store.archivedDays.isEmpty {
            return "Earlier copies are in the day folders."
        }
        if store.items.isEmpty && store.archivedDays.isEmpty {
            return "Copy text or an image and it will show up here."
        }
        return "Try a different search."
    }

    private func clipButton(_ item: ClipItem) -> some View {
        Button {
            onCommit(item)
        } label: {
            ClipRow(item: item, store: store, showsExactTime: pastDay != nil)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                .contentShape(Rectangle())
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
                let dayID = session.selectedDayID
                store.togglePin(id: item.id)
                restoreTodayIfNeeded(dayID)
            }
            Button("Delete", role: .destructive) {
                let dayID = session.selectedDayID
                store.delete(id: item.id)
                restoreTodayIfNeeded(dayID)
            }
        }
    }

    private func restoreTodayIfNeeded(_ dayID: String?) {
        guard let dayID, !store.archivedDays.contains(where: { $0.id == dayID }) else { return }
        session.showToday(in: store)
    }

    private func itemCount(_ count: Int) -> String {
        count == 1 ? "1 item" : "\(count) items"
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
            if pastDay != nil {
                Button("Delete Day") {
                    dayPendingDelete = session.selectedDayID
                    confirmDeleteDay = true
                }
            } else {
                Button("Clear") { confirmClear = true }
                    .disabled(store.unpinnedCount == 0)
            }
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

private struct DayRowButtonStyle: ButtonStyle {
    var isSelected: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(rowFill(isPressed: configuration.isPressed))
            )
            .contentShape(Rectangle())
    }

    private func rowFill(isPressed: Bool) -> Color {
        if isSelected {
            return Color.accentColor.opacity(isPressed ? 0.5 : 0.35)
        }
        return isPressed ? Color.white.opacity(0.08) : Color.clear
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
