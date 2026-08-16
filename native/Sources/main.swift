import Foundation

@main
enum MirrorCtl {
    static func main() {
        let args = Array(CommandLine.arguments.dropFirst())
        guard let command = args.first else {
            JSONOut.print([
                "ok": false,
                "error": "usage: mirror-ctl status|screenshot|tap|swipe|scroll|ocr|type|key|menu",
            ])
            exit(2)
        }
        let flags = parseFlags(Array(args.dropFirst()))
        do {
            switch command {
            case "status":
                JSONOut.print(try status())
            case "screenshot":
                guard let out = flags["out"] else { throw MirrorError.invalidArgs("screenshot requires --out") }
                JSONOut.print(try Capture.screenshot(to: out))
            case "tap":
                let mode = InputMode(rawValue: flags["mode"] ?? "skylight") ?? .skylight
                guard let x = double(flags["x"]), let y = double(flags["y"]) else {
                    throw MirrorError.invalidArgs("tap requires --x --y")
                }
                let overlay = flags["overlay"] != "false"
                JSONOut.print(try Input.tap(x: x, y: y, mode: mode, overlay: overlay))
            case "swipe":
                let mode = InputMode(rawValue: flags["mode"] ?? "hid") ?? .hid
                guard let x1 = double(flags["x1"]), let y1 = double(flags["y1"]),
                      let x2 = double(flags["x2"]), let y2 = double(flags["y2"]) else {
                    throw MirrorError.invalidArgs("swipe requires --x1 --y1 --x2 --y2")
                }
                let duration = Int(flags["duration-ms"] ?? "180") ?? 180
                JSONOut.print(try Input.swipe(x1: x1, y1: y1, x2: x2, y2: y2, durationMs: duration, mode: mode))
            case "scroll":
                guard let x = double(flags["x"]), let y = double(flags["y"]) else {
                    throw MirrorError.invalidArgs("scroll requires --x --y")
                }
                let delta = Int(flags["delta"] ?? "-12") ?? -12
                let ticks = Int(flags["ticks"] ?? "8") ?? 8
                JSONOut.print(try Input.scroll(x: x, y: y, delta: delta, ticks: ticks))
            case "ocr":
                guard let image = flags["image"] else { throw MirrorError.invalidArgs("ocr requires --image") }
                JSONOut.print(
                    try OCR.recognize(
                        imageAt: image,
                        query: flags["query"] ?? "",
                        x0: double(flags["x0"]) ?? 0,
                        y0: double(flags["y0"]) ?? 0,
                        x1: double(flags["x1"]) ?? 1,
                        y1: double(flags["y1"]) ?? 1,
                        limit: Int(flags["limit"] ?? "8") ?? 8
                    )
                )
            case "type":
                let mode = InputMode(rawValue: flags["mode"] ?? "hid") ?? .hid
                guard let text = flags["text"] else { throw MirrorError.invalidArgs("type requires --text") }
                JSONOut.print(try Input.typeText(text, mode: mode))
            case "key":
                let mode = InputMode(rawValue: flags["mode"] ?? "hid") ?? .hid
                guard let name = flags["name"] else { throw MirrorError.invalidArgs("key requires --name") }
                JSONOut.print(try Input.pressNamedKey(name, mode: mode))
            case "menu":
                guard let action = flags["action"] else { throw MirrorError.invalidArgs("menu requires --action") }
                JSONOut.print(try MenuControl.invoke(action))
            default:
                throw MirrorError.invalidArgs("unknown command: \(command)")
            }
        } catch {
            JSONOut.fail(error)
        }
    }

    static func status() throws -> [String: Any] {
        let trusted = WindowFinder.accessibilityTrusted(prompt: false)
        guard WindowFinder.app() != nil else {
            return [
                "ok": true,
                "running": false,
                "accessibilityTrusted": trusted,
                "bundleId": WindowFinder.bundleId,
            ]
        }
        let win = try WindowFinder.find()
        return [
            "ok": true,
            "running": true,
            "connected": win.width >= 200 && win.height >= 400,
            "pid": win.pid,
            "windowId": win.windowId,
            "x": win.x,
            "y": win.y,
            "width": win.width,
            "height": win.height,
            "ownerName": win.ownerName,
            "windowName": win.windowName,
            "accessibilityTrusted": trusted,
            "bundleId": WindowFinder.bundleId,
        ]
    }

    static func parseFlags(_ args: [String]) -> [String: String] {
        var out: [String: String] = [:]
        var i = 0
        while i < args.count {
            var key = args[i]
            if key.hasPrefix("--") { key = String(key.dropFirst(2)) }
            if i + 1 < args.count, !args[i + 1].hasPrefix("--") {
                out[key] = args[i + 1]
                i += 2
            } else {
                out[key] = "true"
                i += 1
            }
        }
        return out
    }

    static func double(_ raw: String?) -> Double? {
        guard let raw else { return nil }
        return Double(raw)
    }
}
