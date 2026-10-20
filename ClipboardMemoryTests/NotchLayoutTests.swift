import Foundation
import Testing
@testable import ClipboardMemory

struct NotchLayoutTests {
    private let screen = NSRect(x: 0, y: 0, width: 1800, height: 1169)
    private let visible = NSRect(x: 0, y: 0, width: 1800, height: 1130)
    private let notch = NSRect(x: 790, y: 1131, width: 220, height: 38)

    @Test func shapeHangsFromTheTopOfTheScreen() {
        for phase in [NotchPhase.idle, .hover, .open] {
            let frame = NotchLayout.windowFrame(
                phase: phase,
                notch: notch,
                screenFrame: screen,
                visibleFrame: visible
            )
            #expect(frame.maxY == screen.maxY)
            #expect(frame.midX == 900)
        }
    }

    @Test func hoverGrowsDownFromTheNotch() {
        let hover = NotchLayout.windowFrame(phase: .hover, notch: notch, screenFrame: screen, visibleFrame: visible)
        #expect(hover.width > notch.width)
        #expect(hover.height > notch.height)
    }

    @Test func idleHitRectIsOnlyTheNotch() {
        let hit = NotchLayout.idleHitRect(notch: notch, screenFrame: screen, visibleFrame: visible)
        #expect(hit.contains(CGPoint(x: 900, y: 1150)))
        #expect(!hit.contains(CGPoint(x: 40, y: 1150)))
        #expect(!hit.contains(CGPoint(x: 1700, y: 1150)))
    }
}
