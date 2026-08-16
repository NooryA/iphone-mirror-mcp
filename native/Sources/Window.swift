import Foundation
import CoreGraphics
import AppKit
import ApplicationServices

struct MirrorWindow: Codable {
    var pid: Int32
    var windowId: UInt32
    var x: Double
    var y: Double
    var width: Double
    var height: Double
    var ownerName: String
    var windowName: String
    var layer: Int
}

enum MirrorError: Error, CustomStringConvertible {
    case notRunning
    case noWindow
    case captureFailed(String)
    case outsideWindow
    case invalidArgs(String)
    case permission(String)

    var description: String {
        switch self {
        case .notRunning:
            return "iPhone Mirroring is not running (com.apple.ScreenContinuity)"
        case .noWindow:
            return "iPhone Mirroring is running but no on-screen window was found"
        case .captureFailed(let m):
            return "screenshot failed: \(m)"
        case .outsideWindow:
            return "refusing to click outside the iPhone Mirroring window"
        case .invalidArgs(let m):
            return m
        case .permission(let m):
            return m
        }
    }
}

enum MirrorMetrics {
    static let defaultTitlebar: Double = 52

    static var titlebarPoints: Double {
        if let raw = ProcessInfo.processInfo.environment["MIRROR_TITLEBAR_PT"],
           let value = Double(raw) {
            return max(0, value)
        }
        return defaultTitlebar
    }
}

enum WindowFinder {
    static let bundleId = "com.apple.ScreenContinuity"
    static let ownerName = "iPhone Mirroring"

    static func app() -> NSRunningApplication? {
        NSWorkspace.shared.runningApplications.first { $0.bundleIdentifier == bundleId }
    }

    static func find() throws -> MirrorWindow {
        guard let app = app() else { throw MirrorError.notRunning }
        let pid = app.processIdentifier
        let opts: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let info = CGWindowListCopyWindowInfo(opts, kCGNullWindowID) as? [[String: Any]] else {
            throw MirrorError.noWindow
        }

        var best: MirrorWindow?
        var bestArea: Double = 0
        for w in info {
            let ownerPid = w[kCGWindowOwnerPID as String] as? pid_t
            let owner = w[kCGWindowOwnerName as String] as? String ?? ""
            guard ownerPid == pid || owner == ownerName else { continue }
            let layer = w[kCGWindowLayer as String] as? Int ?? 0
            guard layer == 0 else { continue }
            let bounds = w[kCGWindowBounds as String] as? [String: Any] ?? [:]
            let x = (bounds["X"] as? NSNumber)?.doubleValue ?? 0
            let y = (bounds["Y"] as? NSNumber)?.doubleValue ?? 0
            let width = (bounds["Width"] as? NSNumber)?.doubleValue ?? 0
            let height = (bounds["Height"] as? NSNumber)?.doubleValue ?? 0
            let area = width * height
            guard area > bestArea, width > 80, height > 80 else { continue }
            let wid = UInt32((w[kCGWindowNumber as String] as? NSNumber)?.uint32Value ?? 0)
            bestArea = area
            best = MirrorWindow(
                pid: pid,
                windowId: wid,
                x: x,
                y: y,
                width: width,
                height: height,
                ownerName: owner,
                windowName: w[kCGWindowName as String] as? String ?? "",
                layer: layer
            )
        }
        guard let found = best else { throw MirrorError.noWindow }
        return found
    }

    static func contains(_ win: MirrorWindow, x: Double, y: Double) -> Bool {
        x >= win.x - 0.5 && x <= win.x + win.width + 0.5
            && y >= win.y - 0.5 && y <= win.y + win.height + 0.5
    }

    /// Window-local AppKit point (origin bottom-left of the window).
    /// `p` is CGWindowList / CGWarp space (origin top-left of the main display).
    static func localPoint(_ p: CGPoint, in win: MirrorWindow) -> CGPoint {
        CGPoint(x: p.x - win.x, y: (win.y + win.height) - p.y)
    }

    /// Convert `NSEvent.mouseLocation` (AppKit, origin bottom-left) to CGWarp space.
    static func warpPoint(fromAppKit ns: CGPoint) -> CGPoint {
        let screenH = NSScreen.main?.frame.height ?? CGDisplayBounds(CGMainDisplayID()).height
        return CGPoint(x: ns.x, y: screenH - ns.y)
    }

    /// Inverse of `warpPoint` — overlay windows live in AppKit space.
    static func appKitPoint(fromWarp p: CGPoint) -> CGPoint {
        let screenH = NSScreen.main?.frame.height ?? CGDisplayBounds(CGMainDisplayID()).height
        return CGPoint(x: p.x, y: screenH - p.y)
    }

    static func accessibilityTrusted(prompt: Bool) -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: prompt] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }
}

enum JSONOut {
    static func print(_ object: [String: Any]) {
        let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data("\n".utf8))
    }

    static func fail(_ error: Error) -> Never {
        let message = (error as? MirrorError)?.description ?? String(describing: error)
        print(["ok": false, "error": message])
        exit(1)
    }
}
