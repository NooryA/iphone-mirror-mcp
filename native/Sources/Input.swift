import Foundation
import CoreGraphics
import AppKit
import ApplicationServices

enum InputMode: String {
    case background
    case hid
}

enum Input {
    private static var mouseEventNumber = 0
    private static let clickHoldUs: UInt32 = 180_000
    private static let restoreDelayUs: UInt32 = 450_000

    static func tap(x: Double, y: Double, mode: InputMode) throws -> [String: Any] {
        let win = try WindowFinder.find()
        guard WindowFinder.contains(win, x: x, y: y) else { throw MirrorError.outsideWindow }
        let point = CGPoint(x: x, y: y)
        let trusted = WindowFinder.accessibilityTrusted(prompt: true)
        let extras = try postClick(to: win, at: point, hid: mode == .hid)
        var result: [String: Any] = [
            "ok": true,
            "mode": mode.rawValue,
            "x": x,
            "y": y,
            "windowId": win.windowId,
            "pid": win.pid,
            "accessibilityTrusted": trusted,
            "cursorMoved": mode == .hid,
        ]
        for (k, v) in extras { result[k] = v }
        return result
    }

    static func swipe(
        x1: Double, y1: Double, x2: Double, y2: Double,
        durationMs: Int,
        mode: InputMode
    ) throws -> [String: Any] {
        let win = try WindowFinder.find()
        guard WindowFinder.contains(win, x: x1, y: y1) else { throw MirrorError.outsideWindow }
        guard WindowFinder.contains(win, x: x2, y: y2) else { throw MirrorError.outsideWindow }
        _ = WindowFinder.accessibilityTrusted(prompt: true)
        try postSwipe(
            to: win,
            from: CGPoint(x: x1, y: y1),
            to: CGPoint(x: x2, y: y2),
            durationMs: durationMs,
            hid: mode == .hid
        )
        return [
            "ok": true,
            "mode": mode.rawValue,
            "x1": x1, "y1": y1, "x2": x2, "y2": y2,
            "durationMs": durationMs,
            "cursorMoved": mode == .hid,
        ]
    }

    static func typeText(_ text: String, mode: InputMode) throws -> [String: Any] {
        let win = try WindowFinder.find()
        _ = WindowFinder.accessibilityTrusted(prompt: true)
        if mode == .hid {
            activate(win.pid)
        }
        try postCharacters(text, pid: win.pid, hid: mode == .hid)
        return ["ok": true, "mode": mode.rawValue, "length": text.count, "cursorMoved": false]
    }

    static func pressNamedKey(_ name: String, mode: InputMode) throws -> [String: Any] {
        let win = try WindowFinder.find()
        _ = WindowFinder.accessibilityTrusted(prompt: true)
        if mode == .hid {
            activate(win.pid)
        }
        try postKey(try keyCode(name), pid: win.pid, hid: mode == .hid)
        return ["ok": true, "key": name, "mode": mode.rawValue]
    }

    private static func keyCode(_ name: String) throws -> CGKeyCode {
        switch name.lowercased() {
            case "return", "enter": return 36
            case "escape", "esc": return 53
            case "tab": return 48
            case "delete", "backspace": return 51
            case "space": return 49
            case "down", "downarrow": return 125
            case "up", "uparrow": return 126
            case "left", "leftarrow": return 123
            case "right", "rightarrow": return 124
        default:
            throw MirrorError.invalidArgs("unknown key: \(name)")
        }
    }

    private static func activate(_ pid: pid_t) {
        guard let app = NSRunningApplication(processIdentifier: pid) else { return }
        if app.isActive {
            usleep(40_000)
            return
        }
        app.activate()
        usleep(400_000)
    }

    private static func applyFields(_ event: CGEvent, win: MirrorWindow) {
        event.setIntegerValueField(.eventTargetUnixProcessID, value: Int64(win.pid))
        event.setIntegerValueField(.mouseEventWindowUnderMousePointer, value: Int64(win.windowId))
        event.setIntegerValueField(
            .mouseEventWindowUnderMousePointerThatCanHandleThisEvent,
            value: Int64(win.windowId)
        )
        if let windowField = CGEventField(rawValue: 51) {
            event.setIntegerValueField(windowField, value: Int64(win.windowId))
        }
    }

    private static func post(_ event: CGEvent, pid: pid_t, hid: Bool) {
        if hid {
            event.post(tap: .cghidEventTap)
        } else {
            event.postToPid(pid)
        }
    }

    private static func hidMouseEvent(
        _ type: NSEvent.EventType,
        local: CGPoint,
        windowId: UInt32,
        clickCount: Int = 1
    ) -> CGEvent? {
        mouseEventNumber += 1
        return NSEvent.mouseEvent(
            with: type,
            location: local,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: Int(windowId),
            context: nil,
            eventNumber: mouseEventNumber,
            clickCount: clickCount,
            pressure: 1.0
        )?.cgEvent
    }

    private static func cgMouseEvent(_ type: CGEventType, at point: CGPoint) -> CGEvent? {
        CGEvent(
            mouseEventSource: CGEventSource(stateID: .hidSystemState),
            mouseType: type,
            mouseCursorPosition: point,
            mouseButton: .left
        )
    }

    private static func saveWarpPoint() -> CGPoint {
        WindowFinder.warpPoint(fromAppKit: NSEvent.mouseLocation)
    }

    /// iPhone Mirroring often ignores warps that appear *inside* the window.
    /// Cross the frame from outside so ScreenContinuity captures the pointer.
    private static func approachFromOutside(to point: CGPoint, win: MirrorWindow) {
        let margin: Double = 36
        let start: CGPoint
        if win.x >= margin + 8 {
            start = CGPoint(x: win.x - margin, y: point.y)
        } else {
            start = CGPoint(x: point.x, y: max(8, win.y - margin))
        }
        CGWarpMouseCursorPosition(start)
        usleep(60_000)
        let steps = 10
        for i in 1...steps {
            let t = Double(i) / Double(steps)
            let p = CGPoint(
                x: start.x + (point.x - start.x) * t,
                y: start.y + (point.y - start.y) * t
            )
            CGWarpMouseCursorPosition(p)
            let local = WindowFinder.localPoint(p, in: win)
            if WindowFinder.contains(win, x: p.x, y: p.y),
               let moved = hidMouseEvent(.mouseMoved, local: local, windowId: win.windowId) {
                post(moved, pid: win.pid, hid: true)
            }
            usleep(18_000)
        }
        CGWarpMouseCursorPosition(point)
        usleep(80_000)
    }

    private static func engageHidCursor(at point: CGPoint, win: MirrorWindow) -> CGPoint {
        let saved = saveWarpPoint()
        approachFromOutside(to: point, win: win)
        return saved
    }

    private static func disengageHidCursor(_ saved: CGPoint) {
        usleep(restoreDelayUs)
        CGWarpMouseCursorPosition(saved)
    }

    /// `cliclick` is what actually reaches iPhone Mirroring on this Mac.
    /// NSEvent/CGEvent HID clicks often no-op even when the cursor warps.
    private static func cliclick(at point: CGPoint) -> Bool {
        let path = "/opt/homebrew/bin/cliclick"
        guard FileManager.default.isExecutableFile(atPath: path) else { return false }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: path)
        let x = Int(point.x.rounded())
        let y = Int(point.y.rounded())
        proc.arguments = ["-r", "w:80", "m:\(x),\(y)", "w:80", "c:."]
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

    private static func postClick(to win: MirrorWindow, at point: CGPoint, hid: Bool) throws -> [String: Any] {
        if hid {
            activate(win.pid)
            if cliclick(at: point) {
                let local = WindowFinder.localPoint(point, in: win)
                return ["localX": local.x, "localY": local.y, "backend": "cliclick"]
            }
        }
        let local = WindowFinder.localPoint(point, in: win)
        var down: CGEvent?
        var up: CGEvent?
        let saved: CGPoint?
        if hid {
            saved = engageHidCursor(at: point, win: win)
            if let moved = hidMouseEvent(.mouseMoved, local: local, windowId: win.windowId) {
                post(moved, pid: win.pid, hid: true)
                usleep(40_000)
            }
            down = hidMouseEvent(.leftMouseDown, local: local, windowId: win.windowId)
            up = hidMouseEvent(.leftMouseUp, local: local, windowId: win.windowId)
        } else {
            saved = nil
            down = cgMouseEvent(.leftMouseDown, at: point)
            up = cgMouseEvent(.leftMouseUp, at: point)
        }
        guard let down, let up else {
            throw MirrorError.invalidArgs("could not create mouse events")
        }
        if !hid {
            applyFields(down, win: win)
            applyFields(up, win: win)
        }
        down.setIntegerValueField(.mouseEventClickState, value: 1)
        up.setIntegerValueField(.mouseEventClickState, value: 1)
        post(down, pid: win.pid, hid: hid)
        usleep(clickHoldUs)
        post(up, pid: win.pid, hid: hid)
        if hid, let saved {
            let restore = ProcessInfo.processInfo.environment["MIRROR_HID_RESTORE"] != "0"
            if restore {
                disengageHidCursor(saved)
            }
        }
        return ["localX": local.x, "localY": local.y]
    }

    private static func postSwipe(
        to win: MirrorWindow,
        from start: CGPoint,
        to end: CGPoint,
        durationMs: Int,
        hid: Bool
    ) throws {
        if hid { activate(win.pid) }
        let steps = max(8, min(40, durationMs / 8))
        let durationUs = UInt32(max(80, durationMs) * 1000)
        let stepUs = durationUs / UInt32(steps)

        func point(at t: Double) -> CGPoint {
            let eased = t * t * (3 - 2 * t)
            return CGPoint(
                x: start.x + (end.x - start.x) * eased,
                y: start.y + (end.y - start.y) * eased
            )
        }

        let first = point(at: 0)
        let saved = hid ? engageHidCursor(at: first, win: win) : nil
        let down: CGEvent?
        if hid {
            down = hidMouseEvent(
                .leftMouseDown,
                local: WindowFinder.localPoint(first, in: win),
                windowId: win.windowId
            )
        } else {
            down = cgMouseEvent(.leftMouseDown, at: first)
        }
        guard let down else { throw MirrorError.invalidArgs("could not create swipe events") }
        if !hid { applyFields(down, win: win) }
        post(down, pid: win.pid, hid: hid)

        for i in 1...steps {
            let p = point(at: Double(i) / Double(steps))
            if hid {
                CGWarpMouseCursorPosition(p)
                if let drag = hidMouseEvent(
                    .leftMouseDragged,
                    local: WindowFinder.localPoint(p, in: win),
                    windowId: win.windowId
                ) {
                    post(drag, pid: win.pid, hid: true)
                }
            } else if let drag = cgMouseEvent(.leftMouseDragged, at: p) {
                applyFields(drag, win: win)
                post(drag, pid: win.pid, hid: false)
            }
            usleep(stepUs)
        }

        let last = point(at: 1)
        let up: CGEvent?
        if hid {
            up = hidMouseEvent(
                .leftMouseUp,
                local: WindowFinder.localPoint(last, in: win),
                windowId: win.windowId
            )
        } else {
            up = cgMouseEvent(.leftMouseUp, at: last)
        }
        if let up {
            if !hid { applyFields(up, win: win) }
            post(up, pid: win.pid, hid: hid)
        }
        if hid, let saved {
            disengageHidCursor(saved)
        }
    }

    private static func postCharacters(_ text: String, pid: pid_t, hid: Bool) throws {
        for ch in text {
            if ch == "\n" {
                try postKey(36, pid: pid, hid: hid)
                continue
            }
            var chars = Array(String(ch).utf16)
            guard let down = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true),
                  let up = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false) else {
                continue
            }
            down.keyboardSetUnicodeString(stringLength: chars.count, unicodeString: &chars)
            up.keyboardSetUnicodeString(stringLength: chars.count, unicodeString: &chars)
            post(down, pid: pid, hid: hid)
            usleep(8_000)
            post(up, pid: pid, hid: hid)
            usleep(12_000)
        }
    }

    private static func postKey(_ code: CGKeyCode, pid: pid_t, hid: Bool) throws {
        guard let down = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: true),
              let up = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: false) else {
            throw MirrorError.invalidArgs("could not create key event")
        }
        post(down, pid: pid, hid: hid)
        usleep(8_000)
        post(up, pid: pid, hid: hid)
    }
}
