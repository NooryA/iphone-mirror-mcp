import Foundation
import CoreGraphics
import AppKit
import ApplicationServices
import Darwin

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

    static func tap(
        x: Double,
        y: Double,
        mode: InputMode,
        overlay: Bool = true,
        preparedWindow: MirrorWindow? = nil
    ) throws -> [String: Any] {
        try requireTapMode(mode)
        let win = try resolvedWindow(preparedWindow)
        guard WindowFinder.contains(win, x: x, y: y) else { throw MirrorError.outsideWindow }
        return try tap(point: CGPoint(x: x, y: y), in: win, mode: mode, overlay: overlay)
    }

    static func tapNormalized(
        x: Double,
        y: Double,
        mode: InputMode,
        overlay: Bool = true,
        preparedWindow: MirrorWindow? = nil
    ) throws -> [String: Any] {
        try requireTapMode(mode)
        let win = try resolvedWindow(preparedWindow)
        let point = try normalizedPoint(x: x, y: y, in: win)
        var result = try tap(point: point, in: win, mode: mode, overlay: overlay)
        result["normalizedX"] = x
        result["normalizedY"] = y
        return result
    }

    private static func tap(
        point: CGPoint,
        in win: MirrorWindow,
        mode: InputMode,
        overlay: Bool
    ) throws -> [String: Any] {
        guard isFrontmost(pid: win.pid) else {
            throw MirrorError.invalidArgs("tap aborted: iPhone Mirroring is no longer frontmost")
        }
        let extras = try postClick(to: win, at: point, mode: mode, overlay: overlay)
        var result: [String: Any] = [
            "ok": true,
            "mode": mode.rawValue,
            "x": point.x,
            "y": point.y,
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
    static func scroll(
        x: Double,
        y: Double,
        delta: Int,
        ticks: Int,
        preparedWindow: MirrorWindow? = nil
    ) throws -> [String: Any] {
        let win = try resolvedWindow(preparedWindow)
        guard WindowFinder.contains(win, x: x, y: y) else { throw MirrorError.outsideWindow }
        return try scroll(point: CGPoint(x: x, y: y), in: win, delta: delta, ticks: ticks)
    }

    static func scrollNormalized(
        x: Double,
        y: Double,
        delta: Int,
        ticks: Int,
        preparedWindow: MirrorWindow? = nil
    ) throws -> [String: Any] {
        let win = try resolvedWindow(preparedWindow)
        let point = try normalizedPoint(x: x, y: y, in: win)
        var result = try scroll(point: point, in: win, delta: delta, ticks: ticks)
        result["normalizedX"] = x
        result["normalizedY"] = y
        return result
    }

    private static func scroll(
        point: CGPoint,
        in win: MirrorWindow,
        delta: Int,
        ticks: Int
    ) throws -> [String: Any] {
        guard isFrontmost(pid: win.pid) else {
            throw MirrorError.invalidArgs("scroll aborted: iPhone Mirroring is no longer frontmost")
        }
        let saved = saveWarpPoint()
        guard cliclickMove(to: point, in: win) else {
            throw MirrorError.invalidArgs(
                "cliclick is required for reliable iPhone Mirroring scrolling"
            )
        }
        let count = max(1, min(40, ticks))
        let wheel = Int32(max(-120, min(120, delta)))
        for tick in 0..<count {
            let current = saveWarpPoint()
            if let reason = globalInputBlockReason(
                frontmost: isFrontmost(pid: win.pid),
                currentPointer: current,
                target: point
            ) {
                throw MirrorError.invalidArgs("scroll aborted before tick \(tick + 1): \(reason)")
            }
            guard let event = CGEvent(
                scrollWheelEvent2Source: nil,
                units: .line,
                wheelCount: 1,
                wheel1: wheel,
                wheel2: 0,
                wheel3: 0
            ) else { throw MirrorError.invalidArgs("could not create scroll-wheel event") }
            event.location = point
            event.post(tap: .cghidEventTap)
            usleep(35_000)
        }
        let userInterference = shouldRestorePointer
            ? restorePointer(saved, expectedCurrent: point)
            : false
        return [
            "ok": true,
            "x": point.x,
            "y": point.y,
            "delta": delta,
            "ticks": count,
            "backend": "scroll-wheel",
            "pointerBackend": "cliclick",
            "cursorMoved": !shouldRestorePointer || userInterference,
            "userInterferenceDetected": userInterference,
        ]
    }

    static func normalizedPoint(x: Double, y: Double, in window: MirrorWindow) throws -> CGPoint {
        guard x.isFinite, y.isFinite, x >= 0, x <= 1, y >= 0, y <= 1 else {
            throw MirrorError.invalidArgs("normalized coordinates must be finite values between 0 and 1")
        }
        let content = WindowFinder.contentRect(window)
        guard content.width > 0, content.height > 0 else {
            throw MirrorError.invalidArgs("iPhone Mirroring content geometry is empty")
        }
        return CGPoint(
            x: min(content.maxX.nextDown, content.minX + x * content.width),
            y: min(content.maxY.nextDown, content.minY + y * content.height)
        )
    }

    private static func requireTapMode(_ mode: InputMode) throws {
        guard mode != .background else {
            throw MirrorError.invalidArgs(
                "background tap events are not delivered to iOS; use hid or skylight"
            )
        }
    }

    static func typeText(
        _ text: String,
        mode: InputMode,
        preparedWindow: MirrorWindow? = nil
    ) throws -> [String: Any] {
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
        let win = try resolvedWindow(preparedWindow)
        let chunks = textChunks(text)
        var typed = 0
        for chunk in chunks {
            _ = try resolvedWindow(win)
            guard cliclickType(chunk) else {
                throw MirrorError.invalidArgs(
                    "cliclick typing failed or timed out after \(typed) of \(text.count) characters"
                )
            }
            typed += chunk.count
        }
        return [
            "ok": true,
            "mode": mode.rawValue,
            "length": text.count,
            "chunks": chunks.count,
            "cursorMoved": false,
            "backend": "cliclick",
        ]
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

    static func prepareForInput() throws -> MirrorWindow {
        try requireAccessibility()
        return try activateAndRefresh(try WindowFinder.find())
    }

    private static func resolvedWindow(_ prepared: MirrorWindow?) throws -> MirrorWindow {
        try requireAccessibility()
        guard let prepared else { return try activateAndRefresh(try WindowFinder.find()) }
        guard isFrontmost(pid: prepared.pid) else {
            throw MirrorError.invalidArgs("iPhone Mirroring focus changed after preflight; no input was sent")
        }
        let current = try WindowFinder.find()
        guard preparedWindowIsCurrent(prepared, current: current) else {
            throw MirrorError.invalidArgs("iPhone Mirroring window changed after preflight; no input was sent")
        }
        return current
    }

    static func preparedWindowIsCurrent(_ prepared: MirrorWindow, current: MirrorWindow) -> Bool {
        prepared.pid == current.pid && prepared.windowId == current.windowId
    }

    private static func activateAndRefresh(_ expected: MirrorWindow) throws -> MirrorWindow {
        guard let app = NSRunningApplication(processIdentifier: expected.pid),
              app.bundleIdentifier == WindowFinder.bundleId else {
            throw MirrorError.invalidArgs("could not resolve the iPhone Mirroring application")
        }
        let confirmed = awaitFrontmost(
            pid: expected.pid,
            activate: { app.isActive || app.activate() },
            frontmostPID: { NSWorkspace.shared.frontmostApplication?.processIdentifier },
            pause: { usleep(25_000) }
        )
        guard confirmed else {
            throw MirrorError.invalidArgs("could not make iPhone Mirroring frontmost; no input was sent")
        }
        let refreshed = try WindowFinder.find()
        guard refreshed.pid == expected.pid, isFrontmost(pid: refreshed.pid) else {
            throw MirrorError.invalidArgs("iPhone Mirroring focus changed before input; no input was sent")
        }
        return refreshed
    }

    static func awaitFrontmost(
        pid: pid_t,
        attempts: Int = 20,
        activate: () -> Bool,
        frontmostPID: () -> pid_t?,
        pause: () -> Void
    ) -> Bool {
        guard activate() else { return false }
        for attempt in 0..<max(1, attempts) {
            if frontmostPID() == pid { return true }
            if attempt + 1 < attempts { pause() }
        }
        return false
    }

    private static func isFrontmost(pid: pid_t) -> Bool {
        NSWorkspace.shared.frontmostApplication?.processIdentifier == pid
    }

    static func pointerRemainsAtTarget(_ current: CGPoint, target: CGPoint) -> Bool {
        hypot(current.x - target.x, current.y - target.y) <= 8
    }

    static func globalInputBlockReason(
        frontmost: Bool,
        currentPointer: CGPoint,
        target: CGPoint
    ) -> String? {
        if !frontmost { return "iPhone Mirroring is no longer frontmost" }
        if !pointerRemainsAtTarget(currentPointer, target: target) {
            return "user pointer movement detected"
        }
        return nil
    }

    static func textChunks(_ text: String, maximumCharacters: Int = 128) -> [String] {
        let limit = max(1, maximumCharacters)
        var chunks: [String] = []
        var start = text.startIndex
        while start < text.endIndex {
            let end = text.index(start, offsetBy: limit, limitedBy: text.endIndex) ?? text.endIndex
            chunks.append(String(text[start..<end]))
            start = end
        }
        return chunks
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
            arguments: cliclickTapArguments(x: x, y: y)
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

    static func cliclickTapArguments(x: Int, y: Int) -> [String] {
        [
            "w:\(cliclickWaitMs)",
            "m:\(cliclickCoordinate(x)),\(cliclickCoordinate(y))",
            "w:\(cliclickWaitMs)",
            "c:\(cliclickCoordinate(x)),\(cliclickCoordinate(y))",
        ]
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

    private static func runCliclick(
        path: String,
        arguments: [String],
        timeoutMs: Int = 5_000
    ) -> Bool {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: path)
        proc.arguments = arguments
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        do {
            try proc.run()
            let deadline = DispatchTime.now().uptimeNanoseconds
                + UInt64(max(1, timeoutMs)) * 1_000_000
            while proc.isRunning, DispatchTime.now().uptimeNanoseconds < deadline {
                usleep(10_000)
            }
            if proc.isRunning {
                proc.terminate()
                let terminateDeadline = DispatchTime.now().uptimeNanoseconds + 250_000_000
                while proc.isRunning, DispatchTime.now().uptimeNanoseconds < terminateDeadline {
                    usleep(10_000)
                }
                if proc.isRunning { kill(proc.processIdentifier, SIGKILL) }
                proc.waitUntilExit()
                return false
            }
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
