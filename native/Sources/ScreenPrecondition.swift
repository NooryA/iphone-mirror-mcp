import CryptoKit
import Foundation

enum ScreenPrecondition {
    @discardableResult
    static func verify(_ expected: String?) throws -> String? {
        guard let expected else { return nil }
        let normalized = expected.lowercased()
        guard normalized.count == 64,
              normalized.allSatisfy({ $0.isHexDigit }) else {
            throw MirrorError.invalidArgs("expected SHA-256 must be 64 hexadecimal characters")
        }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("iphone-mirror-precondition-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: url) }
        _ = try Capture.screenshot(to: url.path)
        let data = try Data(contentsOf: url)
        let actual = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard actual == normalized else {
            throw MirrorError.invalidArgs(
                "screen changed before input (expected \(normalized), current \(actual))"
            )
        }
        return actual
    }
}
