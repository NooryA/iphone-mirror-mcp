import Darwin
import Foundation

/// Serializes global HID input across helper processes and concurrent MCP clients.
final class ActionLock {
    private let descriptor: Int32

    init() throws {
        let directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("iphone-mirror-mcp", isDirectory: true)
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("iphone-mirror-mcp", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let path = directory.appendingPathComponent("input.lock").path
        descriptor = open(path, O_CREAT | O_RDWR | O_CLOEXEC, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else {
            throw MirrorError.lockFailed(String(cString: strerror(errno)))
        }
        guard flock(descriptor, LOCK_EX) == 0 else {
            let message = String(cString: strerror(errno))
            close(descriptor)
            throw MirrorError.lockFailed(message)
        }
    }

    deinit {
        flock(descriptor, LOCK_UN)
        close(descriptor)
    }
}
