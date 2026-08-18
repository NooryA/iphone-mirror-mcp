from __future__ import annotations

import fcntl
import json
import math
import os
import platform
import subprocess
import sys
from pathlib import Path
from typing import Any

from iphone_mirror_mcp import __version__

ROOT = Path(__file__).resolve().parents[2]
BINARY = ROOT / "dist" / "mirror-ctl"
PACKAGE_NATIVE_ROOT = Path(__file__).resolve().parent / "native"


class MirrorCtlError(RuntimeError):
    pass


def _native_binary() -> Path:
    configured = os.environ.get("MIRROR_CTL_PATH")
    if configured:
        path = Path(configured).expanduser()
        if not path.is_file():
            raise MirrorCtlError(f"MIRROR_CTL_PATH does not point to a file: {path}")
        return path
    if BINARY.is_file():
        return BINARY
    if sys.platform != "darwin":
        raise MirrorCtlError("iPhone Mirror MCP requires macOS and the iPhone Mirroring app")

    sources = PACKAGE_NATIVE_ROOT / "Sources"
    builder = PACKAGE_NATIVE_ROOT / "build-native.sh"
    if not sources.is_dir() or not builder.is_file():
        raise MirrorCtlError(
            f"native helper missing at {BINARY}; run scripts/build-native.sh from a repository clone"
        )
    cache_root = Path(
        os.environ.get(
            "MIRROR_NATIVE_CACHE_DIR",
            Path.home() / "Library" / "Caches" / "iphone-mirror-mcp",
        )
    ).expanduser()
    target_dir = cache_root / __version__ / platform.machine()
    target_dir.mkdir(parents=True, exist_ok=True, mode=0o700)
    target = target_dir / "mirror-ctl"
    lock_path = target_dir / "build.lock"
    with lock_path.open("a+b") as lock_handle:
        fcntl.flock(lock_handle.fileno(), fcntl.LOCK_EX)
        env = os.environ.copy()
        env["MIRROR_NATIVE_SRC"] = str(sources)
        env["MIRROR_NATIVE_OUT"] = str(target)
        try:
            built = subprocess.run(
                ["/bin/bash", str(builder)],
                capture_output=True,
                text=True,
                timeout=180,
                check=False,
                env=env,
            )
        except subprocess.TimeoutExpired as exc:
            raise MirrorCtlError("native helper build timed out after 180 seconds") from exc
        if built.returncode != 0 or not target.is_file() or not os.access(target, os.X_OK):
            detail = (built.stderr or built.stdout or "unknown build failure").strip()
            raise MirrorCtlError(f"could not build the native helper: {detail[:800]}")
    return target


def run_ctl(*args: str, timeout: float = 20.0) -> dict[str, Any]:
    binary = _native_binary()
    try:
        proc = subprocess.run(
            [str(binary), *args],
            capture_output=True,
            text=True,
            timeout=timeout,
            check=False,
        )
    except subprocess.TimeoutExpired as exc:
        raise MirrorCtlError(f"mirror-ctl timed out after {timeout:g} seconds") from exc
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
        value = float(raw)
        return max(0.0, value) if math.isfinite(value) else 52.0
    except ValueError:
        return 52.0
