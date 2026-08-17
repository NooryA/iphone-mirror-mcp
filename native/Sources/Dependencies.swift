import Foundation

enum Dependencies {
    private static let knownCliclickPaths = [
        "/opt/homebrew/bin/cliclick",
        "/usr/local/bin/cliclick",
    ]

    static func cliclickPath() -> String? {
        if let configured = ProcessInfo.processInfo.environment["MIRROR_CLICLICK_PATH"],
           isExecutable(configured) {
            return configured
        }
        for path in knownCliclickPaths where isExecutable(path) {
            return path
        }
        for directory in (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":") {
            let path = URL(fileURLWithPath: String(directory), isDirectory: true)
                .appendingPathComponent("cliclick").path
            if isExecutable(path) { return path }
        }
        return nil
    }

    private static func isExecutable(_ path: String) -> Bool {
        guard URL(fileURLWithPath: path).lastPathComponent == "cliclick" else { return false }
        return FileManager.default.isExecutableFile(atPath: path)
    }
}
