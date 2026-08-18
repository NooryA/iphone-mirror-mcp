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
            try captureWithScreenCaptureKit(window: win, to: url)
        } catch {
            do {
                try captureWithScreencapture(win: win, to: url)
            } catch {
                throw MirrorError.captureFailed(
                    "\(error.localizedDescription). Grant Screen Recording to the MCP client app, then retry."
                )
            }
        }
        let titlebar = MirrorMetrics.titlebarPoints
        let scale = WindowFinder.backingScale(for: win)
        let (contentW, contentH) = pngPointSize(at: url, scale: scale)
            ?? (win.width, max(1, win.height - titlebar))
        let content = WindowFinder.contentRect(win)
        let display = WindowFinder.display(for: win)
        return [
            "ok": true,
            "path": path,
            "windowId": win.windowId,
            "width": contentW,
            "height": contentH,
            "windowWidth": win.width,
            "windowHeight": win.height,
            "titlebar": titlebar,
            "titlebarSource": MirrorMetrics.titlebarSource,
            "contentX": content.origin.x,
            "contentY": content.origin.y,
            "contentWidth": content.width,
            "contentHeight": content.height,
            "displayId": display.map { Int($0.id) } ?? -1,
            "displayScale": display?.scale ?? scale,
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
        try cropFileTitlebar(
            url,
            titlebarPoints: MirrorMetrics.titlebarPoints,
            scale: WindowFinder.backingScale(for: win)
        )
    }

    private static func cropTitlebar(_ image: CGImage, titlebarPoints: Double, scale: CGFloat) -> CGImage {
        let top = Int((titlebarPoints * Double(scale)).rounded())
        let height = image.height - top
        guard top > 0, height > 10, image.width > 10 else { return image }
        let rect = CGRect(x: 0, y: top, width: image.width, height: height)
        return image.cropping(to: rect) ?? image
    }

    private static func cropFileTitlebar(_ url: URL, titlebarPoints: Double, scale: CGFloat) throws {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return }
        let cropped = cropTitlebar(image, titlebarPoints: titlebarPoints, scale: scale)
        try writePNG(cropped, to: url)
    }

    private static func captureWithScreenCaptureKit(window: MirrorWindow, to url: URL) throws {
        let sem = DispatchSemaphore(value: 0)
        let outcome = CaptureOutcome()
        Task {
            defer { sem.signal() }
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                guard let scWindow = content.windows.first(where: { $0.windowID == window.windowId }) else {
                    throw MirrorError.captureFailed("ScreenCaptureKit did not list the iPhone Mirroring window")
                }
                let filter = SCContentFilter(desktopIndependentWindow: scWindow)
                let config = SCStreamConfiguration()
                let scale = WindowFinder.backingScale(for: window)
                config.width = max(1, Int(scWindow.frame.width * scale))
                config.height = max(1, Int(scWindow.frame.height * scale))
                config.showsCursor = false
                config.capturesAudio = false
                let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
                let cropped = cropTitlebar(image, titlebarPoints: MirrorMetrics.titlebarPoints, scale: scale)
                outcome.set(cropped)
            } catch {
                outcome.set(error)
            }
        }
        if sem.wait(timeout: .now() + 8) == .timedOut {
            throw MirrorError.captureFailed("ScreenCaptureKit timed out after 8 seconds")
        }
        if let capturedError = outcome.error { throw capturedError }
        guard let image = outcome.image else {
            throw MirrorError.captureFailed("ScreenCaptureKit produced no image")
        }
        try writePNG(image, to: url)
    }

    private static func pngPointSize(at url: URL, scale: CGFloat) -> (Double, Double)? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(src, 0, nil),
              scale > 0 else { return nil }
        return (Double(image.width) / Double(scale), Double(image.height) / Double(scale))
    }

    static func timeoutIsolationSelfTest() -> Bool {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("iphone-mirror-timeout-self-test-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: url) }
        let semaphore = DispatchSemaphore(value: 0)
        let outcome = CaptureOutcome()
        Task {
            usleep(40_000)
            if let image = onePixelImage() { outcome.set(image) }
            semaphore.signal()
        }
        guard semaphore.wait(timeout: .now() + .milliseconds(1)) == .timedOut else {
            return false
        }
        let fallback = Data("fallback-writer-won".utf8)
        do {
            try fallback.write(to: url, options: .atomic)
        } catch {
            return false
        }
        guard semaphore.wait(timeout: .now() + .seconds(1)) == .success else { return false }
        return (try? Data(contentsOf: url)) == fallback && outcome.image != nil
    }

    private static func onePixelImage() -> CGImage? {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: 1,
            height: 1,
            bitsPerComponent: 8,
            bytesPerRow: 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
        return context.makeImage()
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

private final class CaptureOutcome: @unchecked Sendable {
    private let lock = NSLock()
    private var storedError: Error?
    private var storedImage: CGImage?

    var error: Error? {
        lock.lock()
        defer { lock.unlock() }
        return storedError
    }

    var image: CGImage? {
        lock.lock()
        defer { lock.unlock() }
        return storedImage
    }

    func set(_ image: CGImage) {
        lock.lock()
        storedImage = image
        lock.unlock()
    }

    func set(_ error: Error) {
        lock.lock()
        storedError = error
        lock.unlock()
    }
}
