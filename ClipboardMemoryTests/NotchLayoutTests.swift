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

    @Test func externalDisplayActivatesOnlyAtTheVeryTopWithinTheCenteredNotch() {
        let hit = NotchLayout.idleHitRect(
            notch: notch, screenFrame: screen, visibleFrame: visible, activationMode: .topEdge
        )
        for x: CGFloat in [790, 900, 1009] {
            #expect(NotchLayout.containsIdlePointer(
                CGPoint(x: x, y: screen.maxY), in: hit, activationMode: .topEdge
            ))
            #expect(hit.contains(CGPoint(x: x, y: screen.maxY - 0.5)))
            #expect(!hit.contains(CGPoint(x: x, y: screen.maxY - 2)))
            #expect(!hit.contains(CGPoint(x: x, y: visible.maxY)))
        }
        for x: CGFloat in [0, 40, 789, 1010, 1700, 1799] {
            #expect(!NotchLayout.containsIdlePointer(
                CGPoint(x: x, y: screen.maxY), in: hit, activationMode: .topEdge
            ))
            #expect(!hit.contains(CGPoint(x: x, y: screen.maxY - 0.5)))
        }
        #expect(!NotchLayout.containsIdlePointer(
            CGPoint(x: 900, y: screen.maxY + 0.5), in: hit, activationMode: .topEdge
        ))
        #expect(!NotchLayout.containsIdlePointer(
            CGPoint(x: 900, y: screen.maxY - 2), in: hit, activationMode: .topEdge
        ))
    }

    @Test func externalDisplayEdgeUsesScreenCoordinates() {
        let external = NSRect(x: -2560, y: -300, width: 2560, height: 1440)
        let hit = NotchLayout.idleHitRect(
            notch: notch,
            screenFrame: external,
            visibleFrame: external.insetBy(dx: 0, dy: 30),
            activationMode: .topEdge
        )
        #expect(hit.midX == external.midX)
        #expect(hit.width == notch.width)
        #expect(hit.maxY == external.maxY)
        #expect(hit.height == 1)
        #expect(hit.contains(CGPoint(x: -1280, y: 1139.5)))
        #expect(!hit.contains(CGPoint(x: -1280, y: 1138)))
    }
}
