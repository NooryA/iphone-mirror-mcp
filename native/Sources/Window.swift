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

struct DisplayDescriptor {
    var id: CGDirectDisplayID
    var frame: CGRect
    var scale: CGFloat
    var isPrimary: Bool

    var json: [String: Any] {
        [
            "id": id,
            "x": frame.origin.x,
            "y": frame.origin.y,
            "width": frame.width,
            "height": frame.height,
            "scale": scale,
            "isPrimary": isPrimary,
        ]
    }
}

enum MirrorError: Error, CustomStringConvertible {
    case notRunning
    case noWindow
    case captureFailed(String)
    case outsideWindow
    case invalidArgs(String)
    case permission(String)
    case lockFailed(String)

    var description: String {
        switch self {
        case .notRunning:
            return "iPhone Mirroring is not running (com.apple.ScreenContinuity)"
        case .noWindow:
            return "iPhone Mirroring is running but its phone window is not visible on the current Space"
        case .captureFailed(let message):
            return "screenshot failed: \(message)"
        case .outsideWindow:
            return "refusing to click outside the iPhone Mirroring window"
        case .invalidArgs(let message):
            return message
        case .permission(let message):
            return message
        case .lockFailed(let message):
            return "could not serialize input: \(message)"
        }
    }
}

enum MirrorMetrics {
    static let defaultTitlebar: Double = 52

    static var configuredTitlebarPoints: Double? {
        guard let raw = ProcessInfo.processInfo.environment["MIRROR_TITLEBAR_PT"],
              let value = Double(raw), value.isFinite else {
            return nil
        }
        return max(0, value)
    }

    static var titlebarPoints: Double {
        configuredTitlebarPoints ?? defaultTitlebar
    }

    static var titlebarSource: String {
        configuredTitlebarPoints == nil ? "default" : "environment"
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
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let info = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            throw MirrorError.noWindow
        }
        guard let found = selectPhoneWindow(from: info, pid: app.processIdentifier, appName: app.localizedName) else {
            throw MirrorError.noWindow
        }
        return found
    }

    /// Select the actual phone surface, not setup dialogs, menu-bar windows, or overlays.
    static func selectPhoneWindow(
        from info: [[String: Any]],
        pid: pid_t,
        appName: String?
    ) -> MirrorWindow? {
        var candidates: [(window: MirrorWindow, score: Double)] = []
        let expectedTitles = [ownerName, appName ?? ""].filter { !$0.isEmpty }

        for raw in info {
            let ownerPid = raw[kCGWindowOwnerPID as String] as? pid_t
            guard ownerPid == pid else { continue }
            let layer = raw[kCGWindowLayer as String] as? Int ?? 0
            guard layer == 0 else { continue }
            let bounds = raw[kCGWindowBounds as String] as? [String: Any] ?? [:]
            let x = (bounds["X"] as? NSNumber)?.doubleValue ?? 0
            let y = (bounds["Y"] as? NSNumber)?.doubleValue ?? 0
            let width = (bounds["Width"] as? NSNumber)?.doubleValue ?? 0
            let height = (bounds["Height"] as? NSNumber)?.doubleValue ?? 0
            guard width >= 150, height >= 150, width.isFinite, height.isFinite else { continue }

            let windowName = raw[kCGWindowName as String] as? String ?? ""
            let owner = raw[kCGWindowOwnerName as String] as? String ?? ""
            let windowId = UInt32((raw[kCGWindowNumber as String] as? NSNumber)?.uint32Value ?? 0)
            let area = width * height
            let longSide = max(width, height)
            let shortSide = min(width, height)
            let elongated = longSide / max(1, shortSide)
            let exactTitle = expectedTitles.contains {
                windowName.compare($0, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
            }
            let setupDialog = windowName.localizedCaseInsensitiveContains("welcome")
                || windowName.localizedCaseInsensitiveContains("setup")

            var score = min(area, 2_000_000)
            if exactTitle { score += 10_000_000 }
            if elongated >= 1.25 { score += 2_000_000 }
            if windowName.isEmpty { score -= 250_000 }
            if setupDialog { score -= 5_000_000 }

            candidates.append((
                MirrorWindow(
                    pid: pid,
                    windowId: windowId,
                    x: x,
                    y: y,
                    width: width,
                    height: height,
                    ownerName: owner,
                    windowName: windowName,
                    layer: layer
                ),
                score
            ))
        }

        return candidates.max { left, right in left.score < right.score }?.window
    }

    static func contains(_ window: MirrorWindow, x: Double, y: Double) -> Bool {
        x.isFinite && y.isFinite
            && x >= window.x && x < window.x + window.width
            && y >= window.y && y < window.y + window.height
    }

    static func contentRect(_ window: MirrorWindow) -> CGRect {
        let top = min(max(0, MirrorMetrics.titlebarPoints), max(0, window.height - 1))
        return CGRect(x: window.x, y: window.y + top, width: window.width, height: window.height - top)
    }

    /// Window-local AppKit point (origin bottom-left of the window).
    /// `point` is CGWindowList / CGWarp global space (origin top-left of the primary display).
    static func localPoint(_ point: CGPoint, in window: MirrorWindow) -> CGPoint {
        CGPoint(x: point.x - window.x, y: (window.y + window.height) - point.y)
    }

    private static var primaryDisplayHeight: CGFloat {
        CGDisplayBounds(CGMainDisplayID()).height
    }

    /// Convert global AppKit screen coordinates to Quartz display coordinates.
    static func warpPoint(fromAppKit point: CGPoint) -> CGPoint {
        CGPoint(x: point.x, y: primaryDisplayHeight - point.y)
    }

    /// Convert Quartz display coordinates to global AppKit screen coordinates.
    static func appKitPoint(fromWarp point: CGPoint) -> CGPoint {
        CGPoint(x: point.x, y: primaryDisplayHeight - point.y)
    }

    static func appKitRect(for window: MirrorWindow) -> CGRect {
        CGRect(
            x: window.x,
            y: primaryDisplayHeight - CGFloat(window.y + window.height),
            width: window.width,
            height: window.height
        )
    }

    static func displays() -> [DisplayDescriptor] {
        NSScreen.screens.compactMap { screen in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
                return nil
            }
            let id = number.uint32Value
            return DisplayDescriptor(
                id: id,
                frame: screen.frame,
                scale: screen.backingScaleFactor,
                isPrimary: id == CGMainDisplayID()
            )
        }
    }

    static func display(for window: MirrorWindow) -> DisplayDescriptor? {
        let windowRect = appKitRect(for: window)
        return displays().max { left, right in
            intersectionArea(windowRect, left.frame) < intersectionArea(windowRect, right.frame)
        }
    }

    static func backingScale(for window: MirrorWindow) -> CGFloat {
        display(for: window)?.scale ?? 2
    }

    private static func intersectionArea(_ lhs: CGRect, _ rhs: CGRect) -> CGFloat {
        let intersection = lhs.intersection(rhs)
        guard !intersection.isNull else { return 0 }
        return intersection.width * intersection.height
    }

    static func accessibilityTrusted(prompt: Bool) -> Bool {
        // The exported C global is annotated mutable and therefore rejected by
        // Swift 6 strict-concurrency checking. Its documented CFString value is
        // stable, so construct the same options key without touching that global.
        let options = ["AXTrustedCheckOptionPrompt": prompt] as CFDictionary
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
