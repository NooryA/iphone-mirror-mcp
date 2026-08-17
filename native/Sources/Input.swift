import Foundation
import CoreGraphics
import AppKit
import ApplicationServices

enum InputMode: String {
    case background
    case hid
    case skylight
}

enum Input {
    private struct PointerOutcome {
        let userInterference: Bool
        let cursorMoved: Bool
    }

    private static let cliclickWaitMs = 12

    private static var shouldRestorePointer: Bool {
        ProcessInfo.processInfo.environment["MIRROR_HID_RESTORE"] != "0"
    }

    static func tap(x: Double, y: Double, mode: InputMode, overlay: Bool = true) throws -> [String: Any] {
        guard mode != .background else {
            throw MirrorError.invalidArgs(
                "background tap events are not delivered to iOS; use hid or skylight"
            )
        }
        let win = try WindowFinder.find()
        guard WindowFinder.contains(win, x: x, y: y) else { throw MirrorError.outsideWindow }
        let point = CGPoint(x: x, y: y)
        try requireAccessibility()
        let extras = try postClick(to: win, at: point, mode: mode, overlay: overlay)
        var result: [String: Any] = [
            "ok": true,
            "mode": mode.rawValue,
            "x": x,
            "y": y,
            "windowId": win.windowId,
            "pid": win.pid,
            "accessibilityTrusted": true,
            "cursorMoved": extras["cursorMoved"] as? Bool ?? false,
        ]
        for (k, v) in extras { result[k] = v }
        return result
    }

    static func swipe(
        x1: Double, y1: Double, x2: Double, y2: Double,
        durationMs: Int,
        mode: InputMode
    ) throws -> [String: Any] {
        _ = (x1, y1, x2, y2, durationMs, mode)
        throw MirrorError.invalidArgs(
            "drag swipes are not delivered to iOS by iPhone Mirroring; use scroll instead"
        )
    }

    /// A HID scroll-wheel over the window is the most reliable way to scroll ordinary lists.
    /// `delta` is the wheel line delta per tick (negative = show content below).
    static func scroll(x: Double, y: Double, delta: Int, ticks: Int) throws -> [String: Any] {
        let win = try WindowFinder.find()
        guard WindowFinder.contains(win, x: x, y: y) else { throw MirrorError.outsideWindow }
        try requireAccessibility()
        activate(win.pid)
        let saved = saveWarpPoint()
        let point = CGPoint(x: x, y: y)
        guard cliclickMove(to: point, in: win) else {
            throw MirrorError.invalidArgs(
                "cliclick is required for reliable iPhone Mirroring scrolling"
            )
        }
        let count = max(1, min(40, ticks))
        let wheel = Int32(max(-120, min(120, delta)))
        for _ in 0..<count {
            guard let event = CGEvent(
                scrollWheelEvent2Source: nil,
                units: .line,
                wheelCount: 1,
                wheel1: wheel,
                wheel2: 0,
                wheel3: 0
            ) else { throw MirrorError.invalidArgs("could not create scroll-wheel event") }
            event.post(tap: .cghidEventTap)
            usleep(35_000)
        }
        let userInterference = shouldRestorePointer
            ? restorePointer(saved, expectedCurrent: point)
            : false
        return [
            "ok": true,
            "x": x,
            "y": y,
            "delta": delta,
            "ticks": count,
            "backend": "scroll-wheel",
            "pointerBackend": "cliclick",
            "cursorMoved": !shouldRestorePointer || userInterference,
            "userInterferenceDetected": userInterference,
        ]
    }

    static func typeText(_ text: String, mode: InputMode) throws -> [String: Any] {
        guard !text.isEmpty, text.count <= 4_000 else {
            throw MirrorError.invalidArgs("text length must be between 1 and 4000 characters")
        }
        guard !text.contains("\n"), !text.contains("\r") else {
            throw MirrorError.invalidArgs(
                "text must be a single line; named Return events are not delivered to iOS"
            )
        }
        guard mode != .background else {
            throw MirrorError.invalidArgs(
                "background text events are not delivered to iOS; use hid or skylight"
            )
        }
        let win = try WindowFinder.find()
        try requireAccessibility()
        activate(win.pid)
        if cliclickType(text) {
            return [
                "ok": true,
                "mode": mode.rawValue,
                "length": text.count,
                "cursorMoved": false,
                "backend": "cliclick",
            ]
        }
        throw MirrorError.invalidArgs(
            "cliclick is required for reliable iPhone Mirroring keyboard input"
        )
    }

    static func pressNamedKey(_ name: String, mode: InputMode) throws -> [String: Any] {
        _ = (name, mode)
        throw MirrorError.invalidArgs(
            "named key events are not delivered to iOS by iPhone Mirroring; use type_text for text"
        )
    }

    private static func requireAccessibility() throws {
        guard WindowFinder.accessibilityTrusted(prompt: true) else {
            throw MirrorError.permission(
                "Accessibility permission is required for iPhone Mirroring input commands"
            )
        }
    }

    private static func activate(_ pid: pid_t) {
        guard let app = NSRunningApplication(processIdentifier: pid) else { return }
        if app.isActive {
            usleep(8_000)
            return
        }
        app.activate()
        usleep(80_000)
    }

    private static func saveWarpPoint() -> CGPoint {
        WindowFinder.warpPoint(fromAppKit: NSEvent.mouseLocation)
    }

    /// `cliclick` is what actually reaches iPhone Mirroring on this Mac.
    /// NSEvent/CGEvent HID clicks often no-op even when the cursor warps.
    private static func cliclickMove(to point: CGPoint, in window: MirrorWindow) -> Bool {
        guard let path = Dependencies.cliclickPath() else { return false }
        let (x, y) = cliclickPoint(point, in: window)
        return runCliclick(
            path: path,
            arguments: ["w:\(cliclickWaitMs)", "m:\(cliclickCoordinate(x)),\(cliclickCoordinate(y))"]
        )
    }

    /// Returns whether user pointer interference was detected, or nil when the backend failed.
    private static func cliclick(at point: CGPoint, in window: MirrorWindow) -> PointerOutcome? {
        guard let path = Dependencies.cliclickPath() else { return nil }
        let saved = saveWarpPoint()
        let (x, y) = cliclickPoint(point, in: window)
        let succeeded = runCliclick(
            path: path,
            arguments: [
                "w:\(cliclickWaitMs)",
                "m:\(cliclickCoordinate(x)),\(cliclickCoordinate(y))",
                "w:\(cliclickWaitMs)",
                "c:.",
            ]
        )
        let userInterference = shouldRestorePointer
            ? restorePointer(saved, expectedCurrent: point)
            : false
        return succeeded
            ? PointerOutcome(
                userInterference: userInterference,
                cursorMoved: !shouldRestorePointer || userInterference
            )
            : nil
    }

    /// cliclick treats a leading minus as a relative coordinate unless it is prefixed with `=`.
    static func cliclickCoordinate(_ value: Int) -> String {
        value < 0 ? "=\(value)" : "\(value)"
    }

    /// Keep integer pointer coordinates inside Quartz's half-open window bounds.
    static func cliclickPoint(_ point: CGPoint, in window: MirrorWindow) -> (Int, Int) {
        let minX = Int(ceil(window.x))
        let minY = Int(ceil(window.y))
        let maxX = Int(floor((window.x + window.width).nextDown))
        let maxY = Int(floor((window.y + window.height).nextDown))
        let x = min(maxX, max(minX, Int(point.x.rounded())))
        let y = min(maxY, max(minY, Int(point.y.rounded())))
        return (x, y)
    }

    private static func cliclickType(_ text: String) -> Bool {
        guard let path = Dependencies.cliclickPath() else { return false }
        return runCliclick(path: path, arguments: ["t:\(text)"])
    }

    private static func runCliclick(path: String, arguments: [String]) -> Bool {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: path)
        proc.arguments = arguments
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        do {
            try proc.run()
            proc.waitUntilExit()
            return proc.terminationStatus == 0
        } catch {
            return false
        }
    }

    private static func postClick(
        to win: MirrorWindow,
        at point: CGPoint,
        mode: InputMode,
        overlay: Bool
    ) throws -> [String: Any] {
        if mode == .skylight {
            return try postOverlayClick(to: win, at: point, overlay: overlay)
        }
        if mode == .hid {
            activate(win.pid)
            if let outcome = cliclick(at: point, in: win) {
                let local = WindowFinder.localPoint(point, in: win)
                return [
                    "localX": local.x,
                    "localY": local.y,
                    "backend": "cliclick",
                    "cursorMoved": outcome.cursorMoved,
                    "userInterferenceDetected": outcome.userInterference,
                ]
            }
            throw MirrorError.invalidArgs(
                "cliclick is required for reliable iPhone Mirroring taps"
            )
        }
        throw MirrorError.invalidArgs("unsupported tap mode: \(mode.rawValue)")
    }

    /// Overlay cursor plus a short real-pointer click. Synthetic postToPid
    /// events do not become iOS touches in iPhone Mirroring.
    private static func postOverlayClick(
        to win: MirrorWindow,
        at point: CGPoint,
        overlay: Bool
    ) throws -> [String: Any] {
        let started = DispatchTime.now()
        let local = WindowFinder.localPoint(point, in: win)
        let before = NSEvent.mouseLocation
        activate(win.pid)
        if overlay {
            MainActor.assumeIsolated { OverlayCursor.show(atWarp: point) }
        }
        if let outcome = cliclick(at: point, in: win) {
            if overlay {
                MainActor.assumeIsolated { OverlayCursor.hideAfter(ms: 40) }
            }
            let after = NSEvent.mouseLocation
            let elapsedMs = Double(
                DispatchTime.now().uptimeNanoseconds - started.uptimeNanoseconds
            ) / 1_000_000
            return [
                "localX": local.x,
                "localY": local.y,
                "backend": "cliclick-overlay",
                "overlayShown": overlay,
                "cursorMoved": outcome.cursorMoved,
                "cursorBeforeX": before.x,
                "cursorBeforeY": before.y,
                "cursorAfterX": after.x,
                "cursorAfterY": after.y,
                "elapsedMs": elapsedMs,
                "userInterferenceDetected": outcome.userInterference,
            ]
        }
        if overlay {
            MainActor.assumeIsolated { OverlayCursor.hideAfter(ms: 0) }
        }
        throw MirrorError.invalidArgs(
            "cliclick is required for reliable iPhone Mirroring taps"
        )
    }

    /// Do not overwrite a real user movement that occurred while the helper owned the pointer.
    @discardableResult
    private static func restorePointer(_ saved: CGPoint, expectedCurrent: CGPoint) -> Bool {
        let current = saveWarpPoint()
        let userInterference = hypot(current.x - expectedCurrent.x, current.y - expectedCurrent.y) > 8
        if !userInterference {
            CGWarpMouseCursorPosition(saved)
        }
        return userInterference
    }

}
