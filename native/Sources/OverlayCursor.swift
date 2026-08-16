import AppKit
import Foundation

/// Visible agent cursor. Does not receive mouse events and does not move the system pointer.
enum OverlayCursor {
    private static let size = NSSize(width: 28, height: 28)
    private static var panel: NSPanel?

    static func ensureApp() {
        let app = NSApplication.shared
        if app.activationPolicy() != .accessory {
            app.setActivationPolicy(.accessory)
        }
    }

    static func show(atWarp point: CGPoint) {
        ensureApp()
        let appKit = WindowFinder.appKitPoint(fromWarp: point)
        let frame = NSRect(
            x: appKit.x,
            y: appKit.y - size.height,
            width: size.width,
            height: size.height
        )
        let window = panel ?? makePanel()
        panel = window
        window.setFrame(frame, display: true)
        window.orderFrontRegardless()
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.008))
    }

    static func hideAfter(ms: Int) {
        RunLoop.current.run(until: Date(timeIntervalSinceNow: Double(max(0, ms)) / 1000.0))
        panel?.orderOut(nil)
        panel = nil
    }

    private static func makePanel() -> NSPanel {
        let window = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        window.isFloatingPanel = true
        window.level = .screenSaver
        window.ignoresMouseEvents = true
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.hidesOnDeactivate = false
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        window.contentView = CursorView(frame: NSRect(origin: .zero, size: size))
        return window
    }
}

private final class CursorView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        let h = bounds.height
        let path = NSBezierPath()
        path.move(to: NSPoint(x: 2, y: h - 2))
        path.line(to: NSPoint(x: 2, y: h - 22))
        path.line(to: NSPoint(x: 8, y: h - 16))
        path.line(to: NSPoint(x: 16, y: h - 26))
        path.line(to: NSPoint(x: 20, y: h - 22))
        path.line(to: NSPoint(x: 10, y: h - 14))
        path.close()
        NSColor.white.setStroke()
        NSColor(srgbRed: 1, green: 0.42, blue: 0.08, alpha: 1).setFill()
        path.lineWidth = 1.2
        path.fill()
        path.stroke()
    }
}
