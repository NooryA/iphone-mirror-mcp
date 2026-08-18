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
        let text = matches
            .compactMap { $0["text"] as? String }
            .joined(separator: " ")
            .lowercased()
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
        return blockedMarkers.first(where: { text.contains($0.marker) })?.reason
    }

    static func needsAccurateBlockerVerification(from matches: [[String: Any]]) -> Bool {
        let words = matches
            .compactMap { $0["text"] as? String }
            .joined(separator: " ")
            .lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        return words.contains { word in
            word.hasPrefix("connec")
                || word.hasPrefix("paus")
                || word == "unable"
                || word == "lock"
                || word.hasPrefix("icloud")
                || word.hasPrefix("mirror")
                || word.hasPrefix("welcome")
        }
    }
}
