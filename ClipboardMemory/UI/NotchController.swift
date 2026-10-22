import AppKit
import QuartzCore
import SwiftUI

enum NotchLayout {
    static func windowFrame(
        phase: NotchPhase,
        notch: NSRect,
        screenFrame: NSRect,
        visibleFrame: NSRect
    ) -> NSRect {
        let top = screenFrame.maxY
        let size: NSSize
        switch phase {
        case .idle:
            size = notch.size
        case .hover:
            size = NSSize(width: notch.width + 28, height: notch.height + 34)
        case .open:
            size = NSSize(width: 940, height: min(notch.height + 480, visibleFrame.height - 20))
        }
        var rect = NSRect(
            x: notch.midX - size.width / 2,
            y: top - size.height,
            width: size.width,
            height: size.height
        )
        rect.origin.x = min(max(rect.origin.x, screenFrame.minX + 8), screenFrame.maxX - rect.width - 8)
        return rect
    }

    static func idleHitRect(notch: NSRect, screenFrame: NSRect, visibleFrame: NSRect) -> NSRect {
        notch
    }
}

struct NotchMetrics {
    var screen: NSScreen
    var notchRect: NSRect
    var isHardwareNotch: Bool

    static func resolve() -> NotchMetrics {
        for screen in NSScreen.screens {
            guard let left = screen.auxiliaryTopLeftArea,
                  let right = screen.auxiliaryTopRightArea,
                  left.width > 1, right.width > 1, right.minX > left.maxX else { continue }
            let rect = NSRect(
                x: left.maxX,
                y: min(left.minY, right.minY),
                width: right.minX - left.maxX,
                height: max(left.height, right.height)
            )
            return NotchMetrics(screen: screen, notchRect: rect, isHardwareNotch: true)
        }
        let screen = NSScreen.main ?? NSScreen.screens[0]
        let width: CGFloat = 188
        let height: CGFloat = 34
        let rect = NSRect(
            x: screen.frame.midX - width / 2,
            y: screen.frame.maxY - height,
            width: width,
            height: height
        )
        return NotchMetrics(screen: screen, notchRect: rect, isHardwareNotch: false)
    }
}

@MainActor
final class NotchController: NSObject {
    var onCommit: (ClipItem) -> Void = { _ in }
    var onOpenSettings: () -> Void = {}
    var onQuit: () -> Void = {}

    let session = HistorySession()
    private let store: HistoryStore
    private let monitor: ClipboardMonitor
    private let model = NotchModel()
    private let panel: NotchPanel
    private var phase: NotchPhase = .idle
    private var metrics = NotchMetrics.resolve()
    private var animationID = 0
    private var collapseWork: DispatchWorkItem?
    private var keyMonitor: Any?
    private var globalPointerMonitor: Any?
    private var localPointerMonitor: Any?
    private var screenObserver: NSObjectProtocol?

    init(store: HistoryStore, monitor: ClipboardMonitor) {
        self.store = store
        self.monitor = monitor
        panel = NotchPanel(contentRect: .zero)
        super.init()

        let root = NotchView(
            model: model,
            store: store,
            session: session,
            monitor: monitor,
            onCommit: { [weak self] item in self?.onCommit(item) },
            onOpenSettings: { [weak self] in self?.onOpenSettings() },
            onQuit: { [weak self] in self?.onQuit() }
        )
        let hoverView = NotchHoverView(frame: .zero)
        hoverView.onEntered = { [weak self] in self?.pointerEntered() }
        hoverView.onExited = { [weak self] in self?.pointerExited() }
        let hosting = NSHostingView(rootView: root)
        hosting.autoresizingMask = [.width, .height]
        hosting.wantsLayer = true
        hosting.layer?.backgroundColor = NSColor.clear.cgColor
        hoverView.autoresizingMask = [.width, .height]
        hoverView.addSubview(hosting)
        panel.contentView = hoverView
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.isReleasedWhenClosed = false
    }

    func start() {
        metrics = NotchMetrics.resolve()
        model.notchBandHeight = metrics.notchRect.height
        panel.ignoresMouseEvents = false
        panel.colorSpace = metrics.screen.colorSpace
        panel.setFrame(windowFrame(for: .idle), display: true)
        panel.orderFrontRegardless()
        installPointerMonitors()
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.screenChanged()
            }
        }
        if idleHitRect().contains(NSEvent.mouseLocation) {
            setPhase(.hover)
        }
    }

    func toggle() {
        setPhase(phase == .open ? .idle : .open)
    }

    func close() {
        guard phase != .idle else { return }
        setPhase(.idle)
    }

    private func screenChanged() {
        metrics = NotchMetrics.resolve()
        model.notchBandHeight = metrics.notchRect.height
        panel.colorSpace = metrics.screen.colorSpace
        animationID += 1
        panel.setFrame(windowFrame(for: phase), display: true)
    }

    private func pointerEntered() {
        collapseWork?.cancel()
        if phase == .idle {
            setPhase(.hover)
        }
    }

    private func pointerExited() {
        guard phase == .hover else { return }
        scheduleCollapse()
    }

    private func installPointerMonitors() {
        globalPointerMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.mouseMoved, .leftMouseDown, .rightMouseDown]
        ) { [weak self] event in
            let isDown = event.type == .leftMouseDown || event.type == .rightMouseDown
            MainActor.assumeIsolated {
                _ = self?.handlePointer(isDown: isDown)
            }
        }
        localPointerMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.mouseMoved, .leftMouseDown, .rightMouseDown]
        ) { [weak self] event in
            let isDown = event.type == .leftMouseDown || event.type == .rightMouseDown
            let handled = MainActor.assumeIsolated { () -> Bool in
                self?.handlePointer(isDown: isDown) ?? false
            }
            return handled ? nil : event
        }
    }

    @discardableResult
    private func handlePointer(isDown: Bool) -> Bool {
        let point = NSEvent.mouseLocation
        switch phase {
        case .idle:
            guard idleHitRect().contains(point) else { return false }
            setPhase(isDown ? .open : .hover)
            return false
        case .hover:
            let hoverFrame = windowFrame(for: .hover)
            let stay = hoverFrame.union(metrics.notchRect).insetBy(dx: -2, dy: -2)
            if isDown, hoverFrame.union(metrics.notchRect).contains(point) {
                setPhase(.open)
                return hoverFrame.contains(point)
            }
            if stay.contains(point) {
                collapseWork?.cancel()
            } else {
                scheduleCollapse()
            }
            return false
        case .open:
            if isDown, !windowFrame(for: .open).contains(point) {
                setPhase(.idle)
            }
            return false
        }
    }

    private func scheduleCollapse() {
        collapseWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.phase == .hover else { return }
            let hoverFrame = self.windowFrame(for: .hover)
            let stay = hoverFrame.union(self.metrics.notchRect).insetBy(dx: -2, dy: -2)
            if stay.contains(NSEvent.mouseLocation) { return }
            self.setPhase(.idle)
        }
        collapseWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.04, execute: work)
    }

    private func setPhase(_ newPhase: NotchPhase) {
        guard newPhase != phase else { return }
        collapseWork?.cancel()
        let previous = phase
        phase = newPhase
        model.phase = newPhase
        metrics = NotchMetrics.resolve()

        model.notchBandHeight = metrics.notchRect.height
        switch newPhase {
        case .hover:
            model.showsContent = false
            panel.allowsKey = false
            removeKeyMonitor()
            panel.ignoresMouseEvents = false
            panel.orderFrontRegardless()
            animateFrame(to: windowFrame(for: .hover), duration: 0.22)
        case .open:
            model.showsContent = false
            store.archivePastDaysIfNeeded()
            session.reset(in: store)
            monitor.refreshAccessNotice()
            panel.allowsKey = true
            panel.ignoresMouseEvents = false
            panel.orderFrontRegardless()
            animateFrame(to: windowFrame(for: .open), duration: 0.22) { [weak self] in
                guard let self, self.phase == .open else { return }
                self.model.showsContent = true
                self.installKeyMonitor()
                self.panel.makeKey()
                self.focusSearchField()
            }
        case .idle:
            model.showsContent = false
            panel.allowsKey = false
            removeKeyMonitor()
            panel.ignoresMouseEvents = false
            let target = windowFrame(for: .idle)
            if previous == .idle || !panel.isVisible {
                panel.setFrame(target, display: true)
                panel.orderFrontRegardless()
            } else {
                animateFrame(to: target, duration: 0.2) { [weak self] in
                    guard let self, self.phase == .idle else { return }
                    self.panel.orderFrontRegardless()
                }
            }
        }
    }

    private func windowFrame(for phase: NotchPhase) -> NSRect {
        NotchLayout.windowFrame(
            phase: phase,
            notch: metrics.notchRect,
            screenFrame: metrics.screen.frame,
            visibleFrame: metrics.screen.visibleFrame
        )
    }

    private func idleHitRect() -> NSRect {
        NotchLayout.idleHitRect(
            notch: metrics.notchRect,
            screenFrame: metrics.screen.frame,
            visibleFrame: metrics.screen.visibleFrame
        )
    }

    private func animateFrame(
        to target: NSRect,
        duration: TimeInterval,
        completion: (@MainActor () -> Void)? = nil
    ) {
        animationID += 1
        let animationID = animationID
        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.22, 0.8, 0.2, 1)
            context.allowsImplicitAnimation = true
            panel.animator().setFrame(target, display: true)
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.animationID == animationID else { return }
                self.panel.setFrame(target, display: true)
                completion?()
            }
        }
    }

    private func focusSearchField() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if let field = self.session.searchField {
                self.panel.makeFirstResponder(field)
            } else {
                DispatchQueue.main.async { [weak self] in
                    guard let self, let field = self.session.searchField else { return }
                    self.panel.makeFirstResponder(field)
                }
            }
        }
    }

    private func installKeyMonitor() {
        removeKeyMonitor()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let keyCode = event.keyCode
            let modifierRawValue = event.modifierFlags.intersection(.deviceIndependentFlagsMask).rawValue
            let characters = event.charactersIgnoringModifiers
            let handled = MainActor.assumeIsolated { () -> Bool in
                guard let self else { return false }
                return self.handleKey(keyCode: keyCode, modifierRawValue: modifierRawValue, characters: characters)
            }
            return handled ? nil : event
        }
    }

    private func removeKeyMonitor() {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
    }

    private func handleKey(keyCode: UInt16, modifierRawValue: UInt, characters: String?) -> Bool {
        guard phase == .open, panel.isKeyWindow else { return false }
        let flags = NSEvent.ModifierFlags(rawValue: modifierRawValue)
        let command = flags.contains(.command)
        switch keyCode {
        case 53:
            if session.selectedDayID != nil {
                session.showToday(in: store)
                return true
            }
            setPhase(.idle)
            return true
        case 36, 76:
            guard flags.isEmpty else { return false }
            commitSelection()
            return true
        case 126 where !command:
            moveSelection(-1)
            return true
        case 125 where !command:
            moveSelection(1)
            return true
        default:
            break
        }
        guard command else { return false }
        let lowered = characters?.lowercased() ?? ""
        if lowered == "c" || lowered == "a" || lowered == "v" || lowered == "x" {
            return false
        }
        if lowered == "p" {
            guard let id = session.selection else { return true }
            let dayID = session.selectedDayID
            store.togglePin(id: id)
            if let dayID, !store.archivedDays.contains(where: { $0.id == dayID }) {
                session.showToday(in: store)
                return true
            }
            let visible = session.visibleItems(in: store)
            if visible.contains(where: { $0.id == id }) {
                session.selection = id
            } else {
                session.selection = visible.first?.id
            }
            return true
        }
        if keyCode == 51 {
            deleteSelection()
            return true
        }
        if lowered.count == 1, let digit = lowered.first, let value = digit.wholeNumberValue, (1...9).contains(value) {
            commitVisibleIndex(value - 1)
            return true
        }
        return false
    }

    private func commitSelection() {
        let visible = session.visibleItems(in: store)
        guard let item = visible.first(where: { $0.id == session.selection }) ?? visible.first else { return }
        onCommit(item)
    }

    private func commitVisibleIndex(_ index: Int) {
        let visible = session.visibleItems(in: store)
        guard visible.indices.contains(index) else { return }
        onCommit(visible[index])
    }

    private func moveSelection(_ delta: Int) {
        let visible = session.visibleItems(in: store)
        guard !visible.isEmpty else { return }
        guard let selected = session.selection, let current = visible.firstIndex(where: { $0.id == selected }) else {
            session.selection = delta > 0 ? visible.first?.id : visible.last?.id
            return
        }
        let next = min(max(0, current + delta), visible.count - 1)
        session.selection = visible[next].id
    }

    private func deleteSelection() {
        guard let id = session.selection else { return }
        let dayID = session.selectedDayID
        let visible = session.visibleItems(in: store)
        let currentIndex = visible.firstIndex { $0.id == id }
        store.delete(id: id)
        if let dayID, !store.archivedDays.contains(where: { $0.id == dayID }) {
            session.showToday(in: store)
            return
        }
        let updated = session.visibleItems(in: store)
        if let currentIndex, updated.indices.contains(currentIndex) {
            session.selection = updated[currentIndex].id
        } else {
            session.selection = updated.last?.id
        }
    }
}

final class NotchPanel: NSPanel {
    var allowsKey = false

    override var canBecomeKey: Bool { allowsKey }
    override var canBecomeMain: Bool { false }

    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        becomesKeyOnlyIfNeeded = false
        hidesOnDeactivate = false
        level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        isMovable = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        animationBehavior = .none
        acceptsMouseMovedEvents = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }
}

final class NotchHoverView: NSView {
    var onEntered: (@MainActor () -> Void)?
    var onExited: (@MainActor () -> Void)?

    override func layout() {
        super.layout()
        wantsLayer = true
        guard let layer else { return }
        layer.backgroundColor = NotchBlack.cg
        layer.masksToBounds = true
        layer.cornerCurve = .continuous
        layer.isGeometryFlipped = false
        let notchProportion: CGFloat = 8 / 38
        layer.cornerRadius = min(bounds.height * notchProportion, 18)
        layer.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
        for subview in subviews {
            subview.frame = bounds
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas {
            removeTrackingArea(area)
        }
        addTrackingArea(
            NSTrackingArea(
                rect: bounds,
                options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                owner: self,
                userInfo: nil
            )
        )
    }

    override func mouseEntered(with event: NSEvent) {
        MainActor.assumeIsolated { onEntered?() }
    }

    override func mouseExited(with event: NSEvent) {
        MainActor.assumeIsolated { onExited?() }
    }
}
