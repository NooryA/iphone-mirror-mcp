import Foundation

@main
enum MirrorCtl {
    private static let inputCommands: Set<String> = [
        "tap", "swipe", "scroll", "type", "key", "menu", "open-app",
    ]

    static func main() {
        let args = Array(CommandLine.arguments.dropFirst())
        guard let command = args.first else {
            JSONOut.print([
                "ok": false,
                "error": "usage: mirror-ctl status|doctor|self-test|screenshot|tap|swipe|scroll|ocr|type|key|menu|open-app",
            ])
            exit(2)
        }
        let flags = parseFlags(Array(args.dropFirst()))
        do {
            let result: [String: Any]
            if inputCommands.contains(command) {
                let lock = try ActionLock()
                result = try withExtendedLifetime(lock) {
                    try execute(command, flags: flags)
                }
            } else {
                result = try execute(command, flags: flags)
            }
            JSONOut.print(result)
        } catch {
            JSONOut.fail(error)
        }
    }

    static func execute(_ command: String, flags: [String: String]) throws -> [String: Any] {
        if inputCommands.contains(command) {
            _ = try ScreenPrecondition.verify(flags["expected-sha256"])
        }
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
            return try openApp(name)
        default:
            throw MirrorError.invalidArgs("unknown command: \(command)")
        }
    }

    static func parseFlags(_ args: [String]) -> [String: String] {
        var output: [String: String] = [:]
        var index = 0
        while index < args.count {
            var key = args[index]
            if key.hasPrefix("--") { key = String(key.dropFirst(2)) }
            if index + 1 < args.count, !args[index + 1].hasPrefix("--") {
                output[key] = args[index + 1]
                index += 2
            } else {
                output[key] = "true"
                index += 1
            }
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

    static func mode(_ raw: String?, default defaultMode: InputMode) throws -> InputMode {
        guard let raw else { return defaultMode }
        guard let value = InputMode(rawValue: raw) else {
            throw MirrorError.invalidArgs("unknown input mode: \(raw)")
        }
        return value
    }

    private static func openApp(_ name: String) throws -> [String: Any] {
        let spotlight = try MenuControl.invoke("spotlight")
        usleep(450_000)
        let typed = try Input.typeText(name, mode: .hid)

        let screenshot = FileManager.default.temporaryDirectory
            .appendingPathComponent("iphone-mirror-open-app-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: screenshot) }
        var selectedCapture: [String: Any]?
        var selectedOCR: [String: Any]?
        var lastMatchCount = 0
        for attempt in 0..<10 {
            usleep(attempt == 0 ? 400_000 : 300_000)
            try? FileManager.default.removeItem(at: screenshot)
            let capture = try Capture.screenshot(to: screenshot.path)
            let ocr = try OCR.recognize(
                imageAt: screenshot.path,
                query: name,
                x0: 0,
                y0: 0.05,
                x1: 1,
                y1: 0.34,
                limit: 8
            )
            let matches = ocr["matches"] as? [[String: Any]] ?? []
            lastMatchCount = matches.count
            if let exactMatch = matches.first(where: { match in
                guard let text = match["text"] as? String else { return false }
                return text.trimmingCharacters(in: .whitespacesAndNewlines).compare(
                    name,
                    options: [.caseInsensitive, .diacriticInsensitive]
                ) == .orderedSame
            }) {
                selectedCapture = capture
                selectedOCR = exactMatch
                break
            }
        }
        guard let capture = selectedCapture,
              let ocr = selectedOCR,
              let matchedText = ocr["text"] as? String else {
            throw MirrorError.invalidArgs(
                "Spotlight did not show an exact visible result for '\(name)' "
                    + "in the top-result region (last matching OCR count: \(lastMatchCount))"
            )
        }
        guard let normalizedX = (ocr["cx"] as? NSNumber)?.doubleValue,
              let normalizedY = (ocr["cy"] as? NSNumber)?.doubleValue,
              let contentX = (capture["contentX"] as? NSNumber)?.doubleValue,
              let contentY = (capture["contentY"] as? NSNumber)?.doubleValue,
              let contentWidth = (capture["contentWidth"] as? NSNumber)?.doubleValue,
              let contentHeight = (capture["contentHeight"] as? NSNumber)?.doubleValue else {
            throw MirrorError.invalidArgs("Spotlight result geometry was unavailable")
        }
        let globalX = min(
            contentX + contentWidth - 0.5,
            contentX + normalizedX * contentWidth
        )
        let globalY = min(
            contentY + contentHeight - 0.5,
            contentY + normalizedY * contentHeight
        )
        let resultTap = try Input.tap(x: globalX, y: globalY, mode: .skylight)
        return [
            "ok": true,
            "app": name,
            "spotlight": spotlight,
            "typed": typed,
            "result": [
                "text": matchedText,
                "confidence": ocr["confidence"] ?? NSNull(),
                "cx": normalizedX,
                "cy": normalizedY,
            ],
            "tap": resultTap,
        ]
    }
}
