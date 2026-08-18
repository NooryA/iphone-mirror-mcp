import json
import subprocess
import sys
import time
from pathlib import Path

import pytest

from iphone_mirror_mcp import ctl


def test_run_ctl_reads_real_native_self_test() -> None:
    payload = ctl.run_ctl("self-test")
    assert payload["ok"] is True
    assert payload["windowSelection"] is True


def test_run_ctl_rejects_missing_binary(monkeypatch: pytest.MonkeyPatch, tmp_path: Path) -> None:
    monkeypatch.setattr(ctl, "BINARY", tmp_path / "missing")
    with pytest.raises(ctl.MirrorCtlError, match="native helper missing"):
        ctl.run_ctl("status")


@pytest.mark.parametrize(
    ("stdout", "stderr", "returncode", "message"),
    [
        ("", "native failure", 1, "native failure"),
        ("not json", "", 0, "invalid JSON"),
        (json.dumps({"ok": False, "error": "refused"}), "", 1, "refused"),
    ],
)
def test_run_ctl_normalizes_native_failures(
    monkeypatch: pytest.MonkeyPatch,
    tmp_path: Path,
    stdout: str,
    stderr: str,
    returncode: int,
    message: str,
) -> None:
    binary = tmp_path / "mirror-ctl"
    binary.touch()
    monkeypatch.setattr(ctl, "BINARY", binary)
    monkeypatch.setattr(
        ctl,
        "_run_process",
        lambda *args, **kwargs: subprocess.CompletedProcess(args[0], returncode, stdout, stderr),
    )
    with pytest.raises(ctl.MirrorCtlError, match=message):
        ctl.run_ctl("status")


def test_run_ctl_normalizes_timeout(monkeypatch: pytest.MonkeyPatch, tmp_path: Path) -> None:
    binary = tmp_path / "mirror-ctl"
    binary.touch()
    monkeypatch.setattr(ctl, "BINARY", binary)

    def timed_out(*args: object, **kwargs: object) -> subprocess.CompletedProcess[str]:
        del args, kwargs
        raise subprocess.TimeoutExpired(str(binary), 0.25)

    monkeypatch.setattr(ctl, "_run_process", timed_out)
    with pytest.raises(ctl.MirrorCtlError, match="timed out after 0.25 seconds"):
        ctl.run_ctl("status", timeout=0.25)


def test_run_ctl_timeout_kills_the_native_process_group(
    monkeypatch: pytest.MonkeyPatch,
    tmp_path: Path,
) -> None:
    started = tmp_path / "started"
    finished = tmp_path / "finished"
    binary = tmp_path / "fake-mirror-ctl"
    binary.write_text(
        f"""#!{sys.executable}
import subprocess
import sys
import time
from pathlib import Path

child_code = "import sys,time; from pathlib import Path; Path(sys.argv[2]).write_text('started'); time.sleep(2); Path(sys.argv[1]).write_text('finished')"
subprocess.Popen([sys.executable, "-c", child_code, sys.argv[1], sys.argv[2]])
while not Path(sys.argv[2]).exists():
    time.sleep(0.01)
time.sleep(60)
"""
    )
    binary.chmod(0o700)
    monkeypatch.setattr(ctl, "BINARY", binary)

    with pytest.raises(ctl.MirrorCtlError, match="timed out after 1 seconds"):
        ctl.run_ctl(str(finished), str(started), timeout=1)

    assert started.is_file()
    deadline = time.monotonic() + 1.5
    while time.monotonic() < deadline and not finished.exists():
        time.sleep(0.05)
    assert not finished.exists()


def test_titlebar_environment_validation(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("MIRROR_TITLEBAR_PT", "61.5")
    assert ctl.titlebar_pt() == 61.5
    monkeypatch.setenv("MIRROR_TITLEBAR_PT", "not-a-number")
    assert ctl.titlebar_pt() == 52.0
    monkeypatch.setenv("MIRROR_TITLEBAR_PT", "-10")
    assert ctl.titlebar_pt() == 0.0
    monkeypatch.setenv("MIRROR_TITLEBAR_PT", "nan")
    assert ctl.titlebar_pt() == 52.0
    monkeypatch.setenv("MIRROR_TITLEBAR_PT", "inf")
    assert ctl.titlebar_pt() == 52.0
