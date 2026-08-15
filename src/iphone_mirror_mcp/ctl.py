from __future__ import annotations

import json
import os
import subprocess
from pathlib import Path
from typing import Any

ROOT = Path(__file__).resolve().parents[2]
BINARY = ROOT / "dist" / "mirror-ctl"


class MirrorCtlError(RuntimeError):
    pass


def run_ctl(*args: str, timeout: float = 20.0) -> dict[str, Any]:
    if not BINARY.is_file():
        raise MirrorCtlError(
            f"native helper missing at {BINARY}. Run scripts/build-native.sh first."
        )
    proc = subprocess.run(
        [str(BINARY), *args],
        capture_output=True,
        text=True,
        timeout=timeout,
        check=False,
    )
    stdout = (proc.stdout or "").strip()
    if not stdout:
        err = (proc.stderr or "").strip() or f"exit {proc.returncode}"
        raise MirrorCtlError(err)
    try:
        payload = json.loads(stdout.splitlines()[-1])
    except json.JSONDecodeError as exc:
        raise MirrorCtlError(f"invalid JSON from mirror-ctl: {stdout[:400]}") from exc
    if proc.returncode != 0 or payload.get("ok") is False:
        raise MirrorCtlError(str(payload.get("error") or stdout))
    return payload


def titlebar_pt() -> float:
    raw = os.environ.get("MIRROR_TITLEBAR_PT", "52")
    try:
        return max(0.0, float(raw))
    except ValueError:
        return 52.0
