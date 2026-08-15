import Foundation
import ScreenCaptureKit
import CoreGraphics
import AppKit
import ImageIO
import UniformTypeIdentifiers

enum Capture {
    static func screenshot(to path: String) throws -> [String: Any] {
        let win = try WindowFinder.find()
        let url = URL(fileURLWithPath: path)
        do {
            try captureWithScreenCaptureKit(windowId: win.windowId, to: url)
        } catch {
            do {
                try captureWithScreencapture(win: win, to: url)
            } catch {
                throw MirrorError.captureFailed(
                    "\(error.localizedDescription). Grant Screen Recording to Cursor, then retry."
                )
            }
        }
        let titlebar = MirrorMetrics.titlebarPoints
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let (contentW, contentH) = pngPointSize(at: url, scale: scale)
            ?? (win.width, max(1, win.height - titlebar))
        return [
            "ok": true,
            "path": path,
            "windowId": win.windowId,
            "width": contentW,
            "height": contentH,
            "windowWidth": win.width,
            "windowHeight": win.height,
            "titlebar": titlebar,
        ]
    }

    private static func captureWithScreencapture(win: MirrorWindow, to url: URL) throws {
        let rect = "\(Int(win.x.rounded())),\(Int(win.y.rounded())),\(Int(win.width.rounded())),\(Int(win.height.rounded()))"
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        proc.arguments = ["-x", "-R", rect, url.path]
        let err = Pipe()
        proc.standardError = err
        try proc.run()
        proc.waitUntilExit()
        if proc.terminationStatus != 0 || !FileManager.default.fileExists(atPath: url.path) {
            let msg = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw MirrorError.captureFailed("screencapture failed: \(msg)")
        }
        try cropFileTitlebar(url, titlebarPoints: MirrorMetrics.titlebarPoints)
    }

    private static func cropTitlebar(_ image: CGImage, titlebarPoints: Double, scale: CGFloat) -> CGImage {
        let top = Int((titlebarPoints * Double(scale)).rounded())
        let height = image.height - top
        guard top > 0, height > 10, image.width > 10 else { return image }
        let rect = CGRect(x: 0, y: top, width: image.width, height: height)
        return image.cropping(to: rect) ?? image
    }

    private static func cropFileTitlebar(_ url: URL, titlebarPoints: Double) throws {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return }
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let cropped = cropTitlebar(image, titlebarPoints: titlebarPoints, scale: scale)
        try writePNG(cropped, to: url)
    }

    private static func captureWithScreenCaptureKit(windowId: UInt32, to url: URL) throws {
        let sem = DispatchSemaphore(value: 0)
        var capturedError: Error?
        Task {
            defer { sem.signal() }
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                guard let scWindow = content.windows.first(where: { $0.windowID == windowId }) else {
                    throw MirrorError.captureFailed("ScreenCaptureKit did not list the iPhone Mirroring window")
                }
                let filter = SCContentFilter(desktopIndependentWindow: scWindow)
                let config = SCStreamConfiguration()
                let scale = NSScreen.main?.backingScaleFactor ?? 2
                config.width = max(1, Int(scWindow.frame.width * scale))
                config.height = max(1, Int(scWindow.frame.height * scale))
                config.showsCursor = false
                config.capturesAudio = false
                let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
                let cropped = cropTitlebar(image, titlebarPoints: MirrorMetrics.titlebarPoints, scale: scale)
                try writePNG(cropped, to: url)
            } catch {
                capturedError = error
            }
        }
        _ = sem.wait(timeout: .now() + 8)
        if let capturedError { throw capturedError }
        if !FileManager.default.fileExists(atPath: url.path) {
            throw MirrorError.captureFailed("ScreenCaptureKit produced no file")
        }
    }

    private static func pngPointSize(at url: URL, scale: CGFloat) -> (Double, Double)? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(src, 0, nil),
              scale > 0 else { return nil }
        return (Double(image.width) / Double(scale), Double(image.height) / Double(scale))
    }

    private static func writePNG(_ image: CGImage, to url: URL) throws {
        let dir = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw MirrorError.captureFailed("could not create PNG destination")
        }
        CGImageDestinationAddImage(dest, image, nil)
        if !CGImageDestinationFinalize(dest) {
            throw MirrorError.captureFailed("could not write PNG")
        }
    }
}
