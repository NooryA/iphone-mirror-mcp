import CryptoKit
import Foundation

struct ScreenPreconditionState {
    let sha256: String
    let visualSignature: String
    let structuralHash: String
    let windowId: UInt32
    let visualDistance: Double?
    let window: MirrorWindow
    let capture: [String: Any]
    let imageData: Data
    let ocrMatches: [[String: Any]]

    var json: [String: Any] {
        var result: [String: Any] = [
            "preflightSha256": sha256,
            "preflightWindowId": Int(windowId),
            "preflightBlockedReason": NSNull(),
        ]
        if let visualDistance {
            result["preflightVisualDistance"] = visualDistance
        }
        return result
    }
}

enum ScreenPrecondition {
    private struct PositionedText {
        let text: String
        let x0: Double
        let y0: Double
        let x1: Double
        let y1: Double

        var centerY: Double { (y0 + y1) / 2 }
        var height: Double { y1 - y0 }
    }

    private struct TextLine {
        var items: [PositionedText]

        var centerY: Double {
            items.map(\.centerY).reduce(0, +) / Double(items.count)
        }

        var meanHeight: Double {
            items.map(\.height).reduce(0, +) / Double(items.count)
        }

        var x0: Double { items.map(\.x0).min() ?? 0 }
        var x1: Double { items.map(\.x1).max() ?? 0 }
        var y0: Double { items.map(\.y0).min() ?? 0 }
        var y1: Double { items.map(\.y1).max() ?? 0 }
    }

    private static let blockedMarkers: [(marker: String, reason: String)] = [
        ("lock your iphone to connect", "iphone_in_use"),
        ("iphone in use", "iphone_in_use"),
        ("icloud signed out", "icloud_signed_out"),
        ("sign in to icloud to continue", "icloud_signed_out"),
        ("welcome to iphone mirroring", "setup_required"),
        ("iphone mirroring not available", "mirroring_unavailable"),
        ("unable to connect to iphone", "connection_unavailable"),
        ("connection paused", "connection_paused"),
    ]

    static func verify(
        window: MirrorWindow,
        expectedSHA256 expected: String?,
        expectedImagePath: String?
    ) throws -> ScreenPreconditionState {
        let normalizedExpected = try validateSHA256(expected)
        let currentURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("iphone-mirror-precondition-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: currentURL) }

        let capture = try Capture.screenshot(window: window, to: currentURL.path)
        let data = try Data(contentsOf: currentURL)
        let actual = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let visual = try VisualComparison.observation(at: currentURL)
        let ocrMatches = try OCR.scan(imageAt: currentURL.path)
        if let blockedReason = blockedReason(from: ocrMatches) {
            throw MirrorError.invalidArgs(
                "interaction blocked by iPhone Mirroring host state: \(blockedReason)"
            )
        }
        if let normalizedExpected, actual != normalizedExpected {
            throw MirrorError.invalidArgs(
                "screen changed before input (expected \(normalizedExpected), current \(actual))"
            )
        }

        var visualDistance: Double?
        if let expectedImagePath {
            let expectedURL = URL(fileURLWithPath: expectedImagePath)
            guard FileManager.default.isReadableFile(atPath: expectedURL.path) else {
                throw MirrorError.invalidArgs("expected visual precondition image is unreadable")
            }
            let distance = try VisualComparison.distance(between: expectedURL, and: currentURL)
            visualDistance = distance
            guard distance <= VisualComparison.materialDifferenceThreshold else {
                throw MirrorError.invalidArgs(
                    "screen changed visually before input "
                        + "(distance \(String(format: "%.3f", distance)), "
                        + "allowed \(VisualComparison.materialDifferenceThreshold))"
                )
            }
        }

        guard let windowId = (capture["windowId"] as? NSNumber)?.uint32Value else {
            throw MirrorError.captureFailed("preflight capture did not report its window identity")
        }
        return ScreenPreconditionState(
            sha256: actual,
            visualSignature: visual.signature,
            structuralHash: visual.structuralHash,
            windowId: windowId,
            visualDistance: visualDistance,
            window: window,
            capture: capture,
            imageData: data,
            ocrMatches: ocrMatches
        )
    }

    static func validateSHA256(_ expected: String?) throws -> String? {
        guard let expected else { return nil }
        let normalized = expected.lowercased()
        guard normalized.count == 64,
              normalized.allSatisfy({ $0.isHexDigit }) else {
            throw MirrorError.invalidArgs("expected SHA-256 must be 64 hexadecimal characters")
        }
        return normalized
    }

    static func blockedReason(from matches: [[String: Any]]) -> String? {
        let normalizedTexts = matches.compactMap { match -> String? in
            guard let text = match["text"] as? String else { return nil }
            let normalized = normalize(text)
            return normalized.isEmpty ? nil : normalized
        }
        for text in normalizedTexts {
            if let reason = reason(in: text) { return reason }
        }

        // Vision normally returns a whole line as one observation. When it splits a warning,
        // only combine observations that are adjacent in geometric reading order. Blindly
        // joining every OCR result can turn unrelated labels such as distant "Connection" and
        // "Paused" controls into a host warning and incorrectly reject all input.
        for run in adjacentTextRuns(from: matches) {
            if let reason = reason(in: run.map(\.text).joined(separator: " ")) {
                return reason
            }
        }
        return nil
    }

    private static func normalize(_ text: String) -> String {
        text.lowercased()
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
    }

    private static func reason(in text: String) -> String? {
        blockedMarkers.first(where: { text.contains($0.marker) })?.reason
    }

    private static func adjacentTextRuns(from matches: [[String: Any]]) -> [[PositionedText]] {
        let positioned = matches.compactMap(positionedText)
            .sorted {
                if $0.centerY != $1.centerY { return $0.centerY < $1.centerY }
                return $0.x0 < $1.x0
            }
        var lines: [TextLine] = []
        for item in positioned {
            if !lines.isEmpty,
               abs(item.centerY - lines[lines.count - 1].centerY)
                   <= 0.6 * max(item.height, lines[lines.count - 1].meanHeight) {
                lines[lines.count - 1].items.append(item)
            } else {
                lines.append(TextLine(items: [item]))
            }
        }
        for index in lines.indices {
            lines[index].items.sort { $0.x0 < $1.x0 }
        }

        var runs: [[PositionedText]] = []
        var previousLine: TextLine?
        for line in lines {
            var segments: [[PositionedText]] = []
            for item in line.items {
                if let previous = segments.last?.last,
                   horizontallyAdjacent(previous, item) {
                    segments[segments.count - 1].append(item)
                } else {
                    segments.append([item])
                }
            }
            if let previousLine, wrapsFrom(previousLine, to: line),
               !runs.isEmpty, !segments.isEmpty {
                runs[runs.count - 1].append(contentsOf: segments.removeFirst())
            }
            runs.append(contentsOf: segments)
            previousLine = line
        }
        return runs
    }

    private static func positionedText(_ match: [String: Any]) -> PositionedText? {
        guard let text = match["text"] as? String,
              let box = match["bbox"] as? [String: Any],
              let x0 = (box["x0"] as? NSNumber)?.doubleValue,
              let y0 = (box["y0"] as? NSNumber)?.doubleValue,
              let x1 = (box["x1"] as? NSNumber)?.doubleValue,
              let y1 = (box["y1"] as? NSNumber)?.doubleValue,
              x0.isFinite, y0.isFinite, x1.isFinite, y1.isFinite,
              x0 >= 0, y0 >= 0, x1 <= 1, y1 <= 1,
              x0 < x1, y0 < y1 else { return nil }
        let normalized = normalize(text)
        guard !normalized.isEmpty else { return nil }
        return PositionedText(text: normalized, x0: x0, y0: y0, x1: x1, y1: y1)
    }

    private static func horizontallyAdjacent(_ left: PositionedText, _ right: PositionedText) -> Bool {
        let maximumGap = max(0.015, 1.75 * max(left.height, right.height))
        return right.x0 - left.x1 <= maximumGap
    }

    private static func wrapsFrom(_ upper: TextLine, to lower: TextLine) -> Bool {
        let maximumVerticalGap = max(0.02, 1.5 * max(upper.meanHeight, lower.meanHeight))
        let verticalGap = lower.y0 - upper.y1
        guard verticalGap >= 0, verticalGap <= maximumVerticalGap else { return false }

        let maximumHorizontalGap = max(0.03, 2 * max(upper.meanHeight, lower.meanHeight))
        return lower.x0 <= upper.x1 + maximumHorizontalGap
            && lower.x1 >= upper.x0 - maximumHorizontalGap
    }

    static func needsAccurateBlockerVerification(from matches: [[String: Any]]) -> Bool {
        let words = matches
            .compactMap { $0["text"] as? String }
            .joined(separator: " ")
            .lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        return words.contains { word in
            word.hasPrefix("conn")
                || word.hasPrefix("pau")
                || word == "unable"
                || word == "lock"
                || word.hasPrefix("icloud")
                || word.hasPrefix("mirror")
                || word.hasPrefix("welcome")
        }
    }
}
