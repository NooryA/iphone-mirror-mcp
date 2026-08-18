import subprocess
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def test_native_action_lock_serializes_independent_processes(tmp_path: Path) -> None:
    probe_source = tmp_path / "LockProbe.swift"
    probe_source.write_text(
        """
        import Darwin
        import Foundation

        @main
        enum LockProbe {
            static func main() {
                do {
                    let lock = try ActionLock()
                    withExtendedLifetime(lock) { usleep(50_000) }
                } catch {
                    exit(1)
                }
            }
        }
        """,
        encoding="utf-8",
    )
    executable = tmp_path / "lock-probe"
    subprocess.run(
        [
            "swiftc",
            "-O",
            "-parse-as-library",
            str(ROOT / "native" / "Sources" / "Window.swift"),
            str(ROOT / "native" / "Sources" / "ActionLock.swift"),
            str(probe_source),
            "-o",
            str(executable),
            "-framework",
            "Cocoa",
            "-framework",
            "ApplicationServices",
            "-framework",
            "CoreGraphics",
        ],
        check=True,
        capture_output=True,
        text=True,
        timeout=30,
    )

    started = time.monotonic()
    processes = [subprocess.Popen([str(executable)]) for _ in range(8)]
    return_codes = [process.wait(timeout=10) for process in processes]
    elapsed = time.monotonic() - started

    assert return_codes == [0] * 8
    assert elapsed >= 0.35
    assert elapsed < 5
