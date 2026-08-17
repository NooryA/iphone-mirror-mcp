import Foundation
import CoreGraphics

enum Diagnostics {
    static func selfTest() -> [String: Any] {
        let pid: pid_t = 4_242
        func fixture(id: UInt32, name: String, width: Double, height: Double) -> [String: Any] {
            [
                kCGWindowOwnerPID as String: pid,
                kCGWindowOwnerName as String: WindowFinder.ownerName,
                kCGWindowLayer as String: 0,
                kCGWindowNumber as String: id,
                kCGWindowName as String: name,
                kCGWindowBounds as String: ["X": 100, "Y": 200, "Width": width, "Height": height],
            ]
        }
        let fixtures = [
            fixture(id: 1, name: "Welcome to iPhone Mirroring", width: 640, height: 658),
            fixture(id: 2, name: "", width: 1_920, height: 37),
            fixture(id: 3, name: "iPhone Mirroring", width: 313, height: 689),
        ]
        let selected = WindowFinder.selectPhoneWindow(from: fixtures, pid: pid, appName: "iPhone Mirroring")
        let sample = CGPoint(x: -1_100, y: 350)
        let roundTrip = WindowFinder.warpPoint(fromAppKit: WindowFinder.appKitPoint(fromWarp: sample))
        let selectionPassed = selected?.windowId == 3
        let coordinatesPassed = hypot(roundTrip.x - sample.x, roundTrip.y - sample.y) < 0.001
        let cliclickCoordinatesPassed = Input.cliclickCoordinate(-1_074) == "=-1074"
            && Input.cliclickCoordinate(846) == "846"
        let edgePoint = Input.cliclickPoint(
            CGPoint(x: -761, y: 1_806),
            in: MirrorWindow(
                pid: pid,
                windowId: 4,
                x: -1_074,
                y: 1_117,
                width: 313,
                height: 689,
                ownerName: WindowFinder.ownerName,
                windowName: WindowFinder.ownerName,
                layer: 0
            )
        )
        let cliclickEdgesPassed = edgePoint == (-762, 1_805)
        return [
            "ok": selectionPassed && coordinatesPassed
                && cliclickCoordinatesPassed && cliclickEdgesPassed,
            "windowSelection": selectionPassed,
            "coordinateRoundTrip": coordinatesPassed,
            "cliclickNegativeCoordinates": cliclickCoordinatesPassed,
            "cliclickHalfOpenEdges": cliclickEdgesPassed,
            "selectedWindowId": selected.map { Int($0.windowId) } ?? -1,
        ]
    }

    static func status() -> [String: Any] {
        let trusted = WindowFinder.accessibilityTrusted(prompt: false)
        guard WindowFinder.app() != nil else {
            return [
                "ok": true,
                "running": false,
                "windowVisible": false,
                "connected": false,
                "accessibilityTrusted": trusted,
                "screenCaptureAllowed": CGPreflightScreenCaptureAccess(),
                "bundleId": WindowFinder.bundleId,
            ]
        }
        do {
            return windowStatus(try WindowFinder.find(), trusted: trusted)
        } catch {
            return [
                "ok": true,
                "running": true,
                "windowVisible": false,
                "connected": false,
                "accessibilityTrusted": trusted,
                "screenCaptureAllowed": CGPreflightScreenCaptureAccess(),
                "bundleId": WindowFinder.bundleId,
                "warning": String(describing: error),
            ]
        }
    }

    static func doctor() -> [String: Any] {
        let status = status()
        let accessibility = status["accessibilityTrusted"] as? Bool ?? false
        let screenCapture = status["screenCaptureAllowed"] as? Bool ?? false
        let visible = status["windowVisible"] as? Bool ?? false
        var warnings: [String] = []
        var notes: [String] = []
        if !accessibility {
            warnings.append("Accessibility permission is not granted to the MCP client")
        }
        if !screenCapture {
            warnings.append("Screen Recording permission is not granted to the responsible client process")
        }
        if WindowFinder.app() == nil {
            warnings.append("iPhone Mirroring is not running")
        } else if !visible {
            warnings.append("The phone window is not visible on the current macOS Space")
        }
        if Dependencies.cliclickPath() == nil {
            warnings.append("cliclick is unavailable; reliable taps, scrolling, and typing are disabled")
        }
        if MirrorMetrics.configuredTitlebarPoints == nil {
            notes.append("Using the tested default 52-point title bar; set MIRROR_TITLEBAR_PT only if calibration is visibly wrong")
        }

        return [
            "ok": true,
            "healthy": warnings.isEmpty,
            "status": status,
            "macOS": ProcessInfo.processInfo.operatingSystemVersionString,
            "architecture": architecture,
            "displays": WindowFinder.displays().map(\.json),
            "cliclickPath": Dependencies.cliclickPath() ?? NSNull(),
            "titlebarPoints": MirrorMetrics.titlebarPoints,
            "titlebarSource": MirrorMetrics.titlebarSource,
            "notes": notes,
            "warnings": warnings,
        ]
    }

    private static func windowStatus(_ window: MirrorWindow, trusted: Bool) -> [String: Any] {
        let content = WindowFinder.contentRect(window)
        let display = WindowFinder.display(for: window)
        let longSide = max(window.width, window.height)
        let shortSide = min(window.width, window.height)
        let phoneLike = longSide / max(1, shortSide) >= 1.25
        return [
            "ok": true,
            "running": true,
            "windowVisible": true,
            "connected": phoneLike,
            "pid": window.pid,
            "windowId": window.windowId,
            "x": window.x,
            "y": window.y,
            "width": window.width,
            "height": window.height,
            "contentX": content.origin.x,
            "contentY": content.origin.y,
            "contentWidth": content.width,
            "contentHeight": content.height,
            "ownerName": window.ownerName,
            "windowName": window.windowName,
            "displayId": display.map { Int($0.id) } ?? -1,
            "displayScale": display?.scale ?? -1,
            "titlebar": MirrorMetrics.titlebarPoints,
            "titlebarSource": MirrorMetrics.titlebarSource,
            "accessibilityTrusted": trusted,
            "screenCaptureAllowed": CGPreflightScreenCaptureAccess(),
            "bundleId": WindowFinder.bundleId,
        ]
    }

    private static var architecture: String {
        #if arch(arm64)
        return "arm64"
        #elseif arch(x86_64)
        return "x86_64"
        #else
        return "unknown"
        #endif
    }
}
