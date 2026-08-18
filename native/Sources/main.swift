import Foundation

@main
enum MirrorCtl {
    private static let inputCommands: Set<String> = [
        "tap", "tap-normalized", "tap-and-capture", "swipe", "scroll", "scroll-normalized",
        "type", "key", "menu", "open-app",
    ]

    private static let allowedFlags: [String: Set<String>] = [
        "status": [],
        "doctor": [],
        "self-test": [],
        "screenshot": ["out"],
        "tap": ["x", "y", "mode", "overlay", "expected-sha256", "expected-image"],
        "tap-normalized": ["x", "y", "mode", "overlay", "expected-sha256", "expected-image"],
        "tap-and-capture": [
            "x", "y", "mode", "overlay", "settle-ms", "out", "expected-sha256", "expected-image",
        ],
        "swipe": ["x1", "y1", "x2", "y2", "duration-ms", "mode", "expected-sha256"],
        "scroll": ["x", "y", "delta", "ticks", "expected-sha256", "expected-image"],
        "scroll-normalized": ["x", "y", "delta", "ticks", "expected-sha256", "expected-image"],
        "ocr": ["image", "query", "x0", "y0", "x1", "y1", "limit"],
        "type": ["text", "mode", "expected-sha256", "expected-image"],
        "key": ["name", "mode", "expected-sha256"],
        "menu": ["action", "expected-sha256", "expected-image"],
        "open-app": ["name", "expected-sha256", "expected-image"],
    ]

    static func main() {
        let args = Array(CommandLine.arguments.dropFirst())
        guard let command = args.first else {
            JSONOut.print([
                "ok": false,
                "error": "usage: mirror-ctl status|doctor|self-test|screenshot|tap-normalized|tap-and-capture|swipe|scroll-normalized|ocr|type|key|menu|open-app",
            ])
            exit(2)
        }
        do {
            guard let allowed = allowedFlags[command] else {
                throw MirrorError.invalidArgs("unknown command: \(command)")
            }
            let flags = try parseFlags(Array(args.dropFirst()), allowed: allowed)
            let result: [String: Any]
            if inputCommands.contains(command) {
                try validateInputArguments(command, flags: flags)
                let lock = try ActionLock()
                result = try withExtendedLifetime(lock) {
                    let preflight = try ScreenPrecondition.verify(
                        expectedSHA256: flags["expected-sha256"],
                        expectedImagePath: flags["expected-image"]
                    )
                    var value = try execute(command, flags: flags, preflight: preflight)
                    for (key, item) in preflight.json { value[key] = item }
                    return value
                }
            } else {
                result = try execute(command, flags: flags, preflight: nil)
            }
            JSONOut.print(result)
        } catch {
            JSONOut.fail(error)
        }
    }

    /// Reject malformed and intentionally unsupported input without requiring a live phone window.
    /// The same validated flags are then executed under the native action lock and screen preflight.
    static func validateInputArguments(_ command: String, flags: [String: String]) throws {
        switch command {
        case "tap", "tap-normalized", "tap-and-capture":
            let inputMode = try mode(flags["mode"], default: .skylight)
            guard inputMode != .background else {
                throw MirrorError.invalidArgs(
                    "background tap events are not delivered to iOS; use hid or skylight"
                )
            }
            guard let x = finiteDouble(flags["x"]), let y = finiteDouble(flags["y"]) else {
                throw MirrorError.invalidArgs("\(command) requires finite --x and --y")
            }
            if command != "tap", !(0...1).contains(x) || !(0...1).contains(y) {
                throw MirrorError.invalidArgs(
                    "normalized coordinates must be finite values between 0 and 1"
                )
            }
            if command == "tap-and-capture" {
                guard flags["out"] != nil else {
                    throw MirrorError.invalidArgs("tap-and-capture requires finite --x --y and --out")
                }
                _ = try strictInt(
                    flags["settle-ms"],
                    default: 300,
                    minimum: 0,
                    maximum: 10_000,
                    name: "settle-ms"
                )
            }
        case "swipe":
            throw MirrorError.invalidArgs(
                "drag swipes are not delivered to iOS by iPhone Mirroring; use scroll instead"
            )
        case "scroll", "scroll-normalized":
            guard let x = finiteDouble(flags["x"]), let y = finiteDouble(flags["y"]) else {
                throw MirrorError.invalidArgs("\(command) requires finite --x and --y")
            }
            if command == "scroll-normalized", !(0...1).contains(x) || !(0...1).contains(y) {
                throw MirrorError.invalidArgs(
                    "normalized coordinates must be finite values between 0 and 1"
                )
            }
            _ = try strictInt(flags["delta"], default: -12, minimum: -120, maximum: 120, name: "delta")
            _ = try strictInt(flags["ticks"], default: 8, minimum: 1, maximum: 40, name: "ticks")
        case "type":
            let inputMode = try mode(flags["mode"], default: .hid)
            guard inputMode != .background else {
                throw MirrorError.invalidArgs(
                    "background text events are not delivered to iOS; use hid or skylight"
                )
            }
            guard let text = flags["text"] else {
                throw MirrorError.invalidArgs("type requires --text")
            }
            guard !text.isEmpty, text.count <= 4_000 else {
                throw MirrorError.invalidArgs("text length must be between 1 and 4000 characters")
            }
            guard !text.contains("\n"), !text.contains("\r") else {
                throw MirrorError.invalidArgs(
                    "text must be a single line; named Return events are not delivered to iOS"
                )
            }
        case "key":
            throw MirrorError.invalidArgs(
                "named key events are not delivered to iOS by iPhone Mirroring; use type_text for text"
            )
        case "menu":
            guard let action = flags["action"], ["home", "app_switcher", "spotlight"].contains(action) else {
                throw MirrorError.invalidArgs("unknown menu action: \(flags["action"] ?? "")")
            }
        case "open-app":
            guard let rawName = flags["name"] else {
                throw MirrorError.invalidArgs("open-app requires --name")
            }
            let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, name.count <= 200,
                  !name.contains("\n"), !name.contains("\r") else {
                throw MirrorError.invalidArgs("app name must be 1-200 characters on one line")
            }
        default:
            throw MirrorError.invalidArgs("unknown input command: \(command)")
        }
    }

    static func execute(
        _ command: String,
        flags: [String: String],
        preflight: ScreenPreconditionState?
    ) throws -> [String: Any] {
        switch command {
        case "status":
            return Diagnostics.status()
        case "doctor":
            return Diagnostics.doctor()
        case "self-test":
            return Diagnostics.selfTest()
        case "screenshot":
            guard let out = flags["out"] else {
                throw MirrorError.invalidArgs("screenshot requires --out")
            }
            return try Capture.screenshot(to: out)
        case "tap":
            let inputMode = try mode(flags["mode"], default: .skylight)
            guard let x = finiteDouble(flags["x"]), let y = finiteDouble(flags["y"]) else {
                throw MirrorError.invalidArgs("tap requires finite --x and --y")
            }
            let overlay = flags["overlay"] != "false"
            return try Input.tap(x: x, y: y, mode: inputMode, overlay: overlay)
        case "tap-normalized":
            let inputMode = try mode(flags["mode"], default: .skylight)
            guard let x = finiteDouble(flags["x"]), let y = finiteDouble(flags["y"]) else {
                throw MirrorError.invalidArgs("tap-normalized requires finite --x and --y")
            }
            let overlay = flags["overlay"] != "false"
            return try Input.tapNormalized(x: x, y: y, mode: inputMode, overlay: overlay)
        case "tap-and-capture":
            let inputMode = try mode(flags["mode"], default: .skylight)
            guard let x = finiteDouble(flags["x"]), let y = finiteDouble(flags["y"]),
                  let output = flags["out"] else {
                throw MirrorError.invalidArgs("tap-and-capture requires finite --x --y and --out")
            }
            let overlay = flags["overlay"] != "false"
            let settle = boundedInt(flags["settle-ms"], default: 300, minimum: 0, maximum: 10_000)
            let tap = try Input.tapNormalized(x: x, y: y, mode: inputMode, overlay: overlay)
            if settle > 0 { usleep(useconds_t(settle * 1_000)) }
            var capture = try Capture.screenshot(to: output)
            capture["tap"] = tap
            capture["settleMs"] = settle
            return capture
        case "swipe":
            let inputMode = try mode(flags["mode"], default: .hid)
            guard let x1 = finiteDouble(flags["x1"]), let y1 = finiteDouble(flags["y1"]),
                  let x2 = finiteDouble(flags["x2"]), let y2 = finiteDouble(flags["y2"]) else {
                throw MirrorError.invalidArgs("swipe requires finite --x1 --y1 --x2 --y2")
            }
            let duration = boundedInt(flags["duration-ms"], default: 180, minimum: 80, maximum: 5_000)
            return try Input.swipe(
                x1: x1,
                y1: y1,
                x2: x2,
                y2: y2,
                durationMs: duration,
                mode: inputMode
            )
        case "scroll":
            guard let x = finiteDouble(flags["x"]), let y = finiteDouble(flags["y"]) else {
                throw MirrorError.invalidArgs("scroll requires finite --x and --y")
            }
            let delta = boundedInt(flags["delta"], default: -12, minimum: -120, maximum: 120)
            let ticks = boundedInt(flags["ticks"], default: 8, minimum: 1, maximum: 40)
            return try Input.scroll(x: x, y: y, delta: delta, ticks: ticks)
        case "scroll-normalized":
            guard let x = finiteDouble(flags["x"]), let y = finiteDouble(flags["y"]) else {
                throw MirrorError.invalidArgs("scroll-normalized requires finite --x and --y")
            }
            let delta = boundedInt(flags["delta"], default: -12, minimum: -120, maximum: 120)
            let ticks = boundedInt(flags["ticks"], default: 8, minimum: 1, maximum: 40)
            return try Input.scrollNormalized(x: x, y: y, delta: delta, ticks: ticks)
        case "ocr":
            guard let image = flags["image"] else {
                throw MirrorError.invalidArgs("ocr requires --image")
            }
            return try OCR.recognize(
                imageAt: image,
                query: flags["query"] ?? "",
                x0: boundedDouble(flags["x0"], default: 0, minimum: 0, maximum: 1),
                y0: boundedDouble(flags["y0"], default: 0, minimum: 0, maximum: 1),
                x1: boundedDouble(flags["x1"], default: 1, minimum: 0, maximum: 1),
                y1: boundedDouble(flags["y1"], default: 1, minimum: 0, maximum: 1),
                limit: boundedInt(flags["limit"], default: 8, minimum: 1, maximum: 32)
            )
        case "type":
            let inputMode = try mode(flags["mode"], default: .hid)
            guard let text = flags["text"] else {
                throw MirrorError.invalidArgs("type requires --text")
            }
            return try Input.typeText(text, mode: inputMode)
        case "key":
            let inputMode = try mode(flags["mode"], default: .hid)
            guard let name = flags["name"] else {
                throw MirrorError.invalidArgs("key requires --name")
            }
            return try Input.pressNamedKey(name, mode: inputMode)
        case "menu":
            guard let action = flags["action"] else {
                throw MirrorError.invalidArgs("menu requires --action")
            }
            return try MenuControl.invoke(action)
        case "open-app":
            guard let rawName = flags["name"] else {
                throw MirrorError.invalidArgs("open-app requires --name")
            }
            let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, name.count <= 200,
                  !name.contains("\n"), !name.contains("\r") else {
                throw MirrorError.invalidArgs("app name must be 1-200 characters on one line")
            }
            guard let preflight else {
                throw MirrorError.invalidArgs("open-app requires an input preflight")
            }
            return try openApp(name, preflight: preflight)
        default:
            throw MirrorError.invalidArgs("unknown command: \(command)")
        }
    }

    static func parseFlags(_ args: [String], allowed: Set<String>) throws -> [String: String] {
        var output: [String: String] = [:]
        var index = 0
        while index < args.count {
            let token = args[index]
            guard token.hasPrefix("--"), token.count > 2 else {
                throw MirrorError.invalidArgs("expected a --flag, got '\(token)'")
            }
            let key = String(token.dropFirst(2))
            guard allowed.contains(key) else {
                throw MirrorError.invalidArgs("unknown flag --\(key)")
            }
            guard output[key] == nil else {
                throw MirrorError.invalidArgs("duplicate flag --\(key)")
            }
            guard index + 1 < args.count else {
                throw MirrorError.invalidArgs("missing value for --\(key)")
            }
            output[key] = args[index + 1]
            index += 2
        }
        return output
    }

    static func finiteDouble(_ raw: String?) -> Double? {
        guard let raw, let value = Double(raw), value.isFinite else { return nil }
        return value
    }

    static func boundedDouble(
        _ raw: String?,
        default defaultValue: Double,
        minimum: Double,
        maximum: Double
    ) -> Double {
        guard let value = finiteDouble(raw) else { return defaultValue }
        return min(maximum, max(minimum, value))
    }

    static func boundedInt(
        _ raw: String?,
        default defaultValue: Int,
        minimum: Int,
        maximum: Int
    ) -> Int {
        guard let raw, let value = Int(raw) else { return defaultValue }
        return min(maximum, max(minimum, value))
    }

    static func strictInt(
        _ raw: String?,
        default defaultValue: Int,
        minimum: Int,
        maximum: Int,
        name: String
    ) throws -> Int {
        guard let raw else { return defaultValue }
        guard let value = Int(raw), value >= minimum, value <= maximum else {
            throw MirrorError.invalidArgs("--\(name) must be an integer between \(minimum) and \(maximum)")
        }
        return value
    }

    static func mode(_ raw: String?, default defaultMode: InputMode) throws -> InputMode {
        guard let raw else { return defaultMode }
        guard let value = InputMode(rawValue: raw) else {
            throw MirrorError.invalidArgs("unknown input mode: \(raw)")
        }
        return value
    }

    private static func openApp(
        _ name: String,
        preflight: ScreenPreconditionState
    ) throws -> [String: Any] {
        let spotlight = try MenuControl.invoke("spotlight")
        let screenshot = FileManager.default.temporaryDirectory
            .appendingPathComponent("iphone-mirror-open-app-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: screenshot) }

        var spotlightEntryDistance = 0.0
        var spotlightConfirmed = false
        for attempt in 0..<12 {
            usleep(attempt == 0 ? 250_000 : 150_000)
            let matches = try captureOCRMatches(to: screenshot, query: "", y0: 0, y1: 0.55)
            let signature = try VisualComparison.signature(at: screenshot)
            spotlightEntryDistance = try VisualComparison.distance(preflight.visualSignature, signature)
            if spotlightEntryDistance > VisualComparison.materialDifferenceThreshold,
               isSpotlightEntryVisible(matches) {
                spotlightConfirmed = true
                break
            }
        }
        guard spotlightConfirmed else {
            throw MirrorError.invalidArgs(
                "Spotlight AX command was accepted but the Spotlight UI was not confirmed; no text was typed"
            )
        }

        let typed = try Input.typeText(name, mode: .hid)
        var selectedOCR: [String: Any]?
        var selectedSignature: String?
        var lastMatchCount = 0
        for attempt in 0..<10 {
            usleep(attempt == 0 ? 400_000 : 300_000)
            let matches = try captureOCRMatches(to: screenshot, query: name, y0: 0.12, y1: 0.55)
            lastMatchCount = matches.count
            if let exactMatch = selectSpotlightResult(matches, appName: name) {
                selectedOCR = exactMatch
                selectedSignature = try VisualComparison.signature(at: screenshot)
                break
            }
        }
        guard let ocr = selectedOCR,
              let querySignature = selectedSignature,
              let matchedText = ocr["text"] as? String else {
            throw MirrorError.invalidArgs(
                "Spotlight did not show an exact visible result for '\(name)' "
                    + "in the top-result region (last matching OCR count: \(lastMatchCount))"
            )
        }
        guard let normalizedX = (ocr["cx"] as? NSNumber)?.doubleValue,
              let normalizedY = (ocr["cy"] as? NSNumber)?.doubleValue else {
            throw MirrorError.invalidArgs("Spotlight result geometry was unavailable")
        }
        let resultTap = try Input.tapNormalized(
            x: normalizedX,
            y: normalizedY,
            mode: .skylight
        )

        var exitDistance = 0.0
        var transitionConfirmed = false
        for attempt in 0..<16 {
            usleep(attempt == 0 ? 350_000 : 250_000)
            let matches = try captureOCRMatches(to: screenshot, query: "", y0: 0, y1: 0.65)
            let signature = try VisualComparison.signature(at: screenshot)
            exitDistance = try VisualComparison.distance(querySignature, signature)
            if exitDistance > VisualComparison.materialDifferenceThreshold,
               !isSpotlightResultsVisible(matches, appName: name) {
                transitionConfirmed = true
                break
            }
        }
        guard transitionConfirmed else {
            throw MirrorError.invalidArgs(
                "Spotlight result click was sent but no transition away from Spotlight was confirmed"
            )
        }
        return [
            "ok": true,
            "app": name,
            "spotlight": spotlight,
            "spotlightEntryConfirmed": true,
            "spotlightEntryVisualDistance": spotlightEntryDistance,
            "typed": typed,
            "result": [
                "text": matchedText,
                "confidence": ocr["confidence"] ?? NSNull(),
                "cx": normalizedX,
                "cy": normalizedY,
            ],
            "tap": resultTap,
            "launchTransitionConfirmed": true,
            "launchVisualDistance": exitDistance,
        ]
    }

    static func selectSpotlightResult(
        _ matches: [[String: Any]],
        appName: String
    ) -> [String: Any]? {
        matches.first(where: { match in
            guard let text = match["text"] as? String,
                  let cy = (match["cy"] as? NSNumber)?.doubleValue,
                  cy >= 0.12, cy <= 0.55 else { return false }
            return normalizedText(text) == normalizedText(appName)
        })
    }

    private static func captureOCRMatches(
        to screenshot: URL,
        query: String,
        y0: Double,
        y1: Double
    ) throws -> [[String: Any]] {
        try? FileManager.default.removeItem(at: screenshot)
        _ = try Capture.screenshot(to: screenshot.path)
        let ocr = try OCR.recognize(
            imageAt: screenshot.path,
            query: query,
            x0: 0,
            y0: y0,
            x1: 1,
            y1: y1,
            limit: 32
        )
        return ocr["matches"] as? [[String: Any]] ?? []
    }

    static func isSpotlightEntryVisible(_ matches: [[String: Any]]) -> Bool {
        let texts = matches.compactMap { $0["text"] as? String }.map(normalizedText)
        let hasSearch = texts.contains(where: { $0 == "search" || $0.contains("search") })
        let hasSuggestions = texts.contains(where: {
            $0.contains("siri suggestions") || $0 == "show less"
        })
        return hasSearch && hasSuggestions
    }

    private static func isSpotlightResultsVisible(
        _ matches: [[String: Any]],
        appName: String
    ) -> Bool {
        let texts = matches.compactMap { $0["text"] as? String }.map(normalizedText)
        return texts.contains("cancel")
            || selectSpotlightResult(matches, appName: appName) != nil
    }

    private static func normalizedText(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
    }
}
