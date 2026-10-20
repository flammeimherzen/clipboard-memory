import KeyboardShortcuts

extension KeyboardShortcuts.Name {
    @MainActor static let togglePanel = Self("togglePanel", initial: .init(.v, modifiers: [.command, .shift]))
}
