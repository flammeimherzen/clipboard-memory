import SwiftUI

enum NotchBlack {
    static let cg = CGColor(red: 0, green: 0, blue: 0, alpha: 1)
    static let swiftUI = Color(.sRGB, red: 0, green: 0, blue: 0, opacity: 1)
}

enum NotchPhase: Equatable {
    case idle
    case hover
    case open
}

@MainActor
@Observable
final class NotchModel {
    var phase: NotchPhase = .idle
    var showsContent = false
    var notchBandHeight: CGFloat = 38
}

struct NotchView: View {
    @Bindable var model: NotchModel
    @Bindable var store: HistoryStore
    @Bindable var session: HistorySession
    var monitor: ClipboardMonitor
    var onCommit: (ClipItem) -> Void
    var onOpenSettings: () -> Void
    var onQuit: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: model.notchBandHeight)
            ZStack {
                if model.showsContent {
                    HistoryView(
                        store: store,
                        session: session,
                        monitor: monitor,
                        chrome: .notch,
                        onCommit: onCommit,
                        onOpenSettings: onOpenSettings,
                        onQuit: onQuit
                    )
                    .transition(.opacity)
                } else if model.phase == .hover {
                    hoverAffordance
                        .transition(.opacity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(NotchBlack.swiftUI)
        .animation(.easeOut(duration: 0.12), value: model.showsContent)
        .preferredColorScheme(.dark)
    }

    private var hoverAffordance: some View {
        VStack(spacing: 6) {
            Image(systemName: "doc.on.clipboard")
                .font(.system(size: 15, weight: .medium))
            Capsule()
                .fill(Color.white.opacity(0.72))
                .frame(width: 32, height: 3)
        }
        .foregroundStyle(.white.opacity(0.92))
        .padding(.bottom, 6)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityLabel("Clipboard history")
    }
}
