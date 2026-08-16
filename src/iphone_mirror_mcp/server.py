from __future__ import annotations

import os
import tempfile
import time
from typing import Any, Literal

from mcp.server.mcpserver import Image, MCPServer

from iphone_mirror_mcp.ctl import run_ctl, titlebar_pt
from iphone_mirror_mcp.geometry import Rect, assert_inside_window, content_rect, normalized_to_global
from iphone_mirror_mcp.screen import annotate_screenshot, find_pixels

mcp = MCPServer(
    "iphone-mirror",
    instructions=(
        "Drive a physical iPhone through the macOS iPhone Mirroring window. "
        "Coordinates are 0-1, origin top-left of the phone content in the screenshot "
        "(Mac title bar is already cropped; the iOS status bar IS in the image — "
        "nav icons are usually y=0.04–0.08, not 0.12). Never flip Y. "
        "Default tap/swipe/type to hid. Prefer tap_label / find_text to click visible "
        "words (Face ID & Passcode, Subscribe, Confirm). Prefer scroll to move Settings "
        "lists — swipe/drag does not scroll iPhone Mirroring. Prefer tap_and_see, "
        "wait_for_change, find_bright, and find_color over sleeping or guessing coordinates. "
        "Default tap mode is skylight: orange overlay cursor plus a hidden HID warp that "
        "crosses into the window (~200ms). Continuity ignores SkyLight/postToPid alone. "
        "Use hid only to debug a visible Mac pointer. "
        "If iphoneInUse is true, stop tapping and tell the user to lock the phone. "
        "Never use press_home to open an app (use open_app). "
        "AX clicks on the Mac hosting view are not iOS touches."
    ),
)

Mode = Literal["background", "hid", "skylight"]


def _window_rect(status: dict) -> Rect:
    return Rect(
        x=float(status["x"]),
        y=float(status["y"]),
        width=float(status["width"]),
        height=float(status["height"]),
    )


def _map_point(nx: float, ny: float, status: dict) -> tuple[float, float]:
    window = _window_rect(status)
    content = content_rect(window, titlebar=titlebar_pt())
    px, py = normalized_to_global(nx, ny, content)
    assert_inside_window(px, py, window)
    return px, py


def _capture() -> tuple[dict[str, Any], str]:
    fd, path = tempfile.mkstemp(prefix="iphone-mirror-", suffix=".png")
    os.close(fd)
    result = run_ctl("screenshot", "--out", path)
    annotate_screenshot(result, path)
    return result, path


def _image_payload(result: dict[str, Any], path: str) -> list:
    return [result, Image(path=path)]


@mcp.tool()
def mirror_status() -> dict:
    """Return whether iPhone Mirroring is running, window bounds, and Accessibility status."""
    return run_ctl("status")


@mcp.tool()
def mirror_screenshot() -> list:
    """Capture the phone content (Mac title bar cropped). width/height are points; pngWidth/pngHeight are pixels. iphoneInUse means the lock-to-connect chrome."""
    return _image_payload(*_capture())


@mcp.tool()
def tap(x: float, y: float, mode: Mode = "skylight") -> dict:
    """Tap the phone screen. x and y are 0-1, origin top-left of the screenshot / phone content.

    Default skylight: orange overlay cursor; hidden real pointer approaches from
    outside the window, HID-clicks, then restores. Your Mac pointer stays put.
    hid: visible cliclick warp (debug). background (postToPid) is ignored by
    iPhone Mirroring for mouse. Prefer tap_and_see when you need to confirm the UI changed.
    """
    status = run_ctl("status")
    px, py = _map_point(x, y, status)
    return run_ctl("tap", "--x", str(px), "--y", str(py), "--mode", mode)


@mcp.tool()
def tap_and_see(
    x: float,
    y: float,
    mode: Mode = "skylight",
    settle_ms: int = 300,
) -> list:
    """Tap, wait settle_ms, then screenshot. Use this instead of tap + sleep + screenshot."""
    tapped = tap(x, y, mode)
    time.sleep(max(0, settle_ms) / 1000.0)
    result, path = _capture()
    result["tap"] = tapped
    result["settleMs"] = settle_ms
    return _image_payload(result, path)


@mcp.tool()
def swipe(
    x1: float,
    y1: float,
    x2: float,
    y2: float,
    duration_ms: int = 180,
    mode: Mode = "hid",
) -> dict:
    """Swipe from (x1,y1) to (x2,y2) in 0-1 phone-content coordinates. Fast flicks work better than slow drags."""
    status = run_ctl("status")
    a = _map_point(x1, y1, status)
    b = _map_point(x2, y2, status)
    return run_ctl(
        "swipe",
        "--x1",
        str(a[0]),
        "--y1",
        str(a[1]),
        "--x2",
        str(b[0]),
        "--y2",
        str(b[1]),
        "--duration-ms",
        str(duration_ms),
        "--mode",
        mode,
    )


@mcp.tool()
def wait_for_change(
    timeout_ms: int = 8000,
    interval_ms: int = 400,
) -> list:
    """Poll screenshots until the PNG changes or timeout. Prefer this over sleeping after a tap or while a sheet loads."""
    baseline, baseline_path = _capture()
    if baseline.get("iphoneInUse"):
        baseline["changed"] = False
        baseline["timedOut"] = False
        baseline["elapsedMs"] = 0
        return _image_payload(baseline, baseline_path)

    started = time.monotonic()
    interval_s = max(50, interval_ms) / 1000.0
    while True:
        elapsed_ms = int((time.monotonic() - started) * 1000)
        if elapsed_ms >= timeout_ms:
            result, path = _capture()
            result["changed"] = result.get("sha256") != baseline.get("sha256")
            result["timedOut"] = not result["changed"]
            result["elapsedMs"] = elapsed_ms
            return _image_payload(result, path)
        time.sleep(interval_s)
        result, path = _capture()
        elapsed_ms = int((time.monotonic() - started) * 1000)
        if result.get("iphoneInUse") or result.get("sha256") != baseline.get("sha256"):
            result["changed"] = result.get("sha256") != baseline.get("sha256")
            result["timedOut"] = False
            result["elapsedMs"] = elapsed_ms
            return _image_payload(result, path)


@mcp.tool()
def find_color(
    r: int,
    g: int,
    b: int,
    tolerance: int = 40,
    x0: float = 0.0,
    y0: float = 0.0,
    x1: float = 1.0,
    y1: float = 1.0,
    min_pixels: int = 20,
) -> dict:
    """Screenshot and return the 0-1 centroid of pixels near (r,g,b). Pass a region (top-right, CTA band) instead of guessing taps."""
    result, path = _capture()
    hit = find_pixels(
        path,
        red=r,
        green=g,
        blue=b,
        tolerance=tolerance,
        x0=x0,
        y0=y0,
        x1=x1,
        y1=y1,
        min_pixels=min_pixels,
    )
    hit["iphoneInUse"] = result.get("iphoneInUse")
    hit["sha256"] = result.get("sha256")
    return hit


@mcp.tool()
def find_bright(
    min_lum: int = 200,
    x0: float = 0.0,
    y0: float = 0.0,
    x1: float = 1.0,
    y1: float = 1.0,
    min_pixels: int = 20,
) -> dict:
    """Screenshot and return the 0-1 centroid of bright pixels. Use a tight region (e.g. top-right 0.75–1.0, 0.02–0.10) for nav icons."""
    result, path = _capture()
    hit = find_pixels(
        path,
        min_lum=min_lum,
        x0=x0,
        y0=y0,
        x1=x1,
        y1=y1,
        min_pixels=min_pixels,
    )
    hit["iphoneInUse"] = result.get("iphoneInUse")
    hit["sha256"] = result.get("sha256")
    return hit


@mcp.tool()
def find_text(
    query: str,
    x0: float = 0.0,
    y0: float = 0.0,
    x1: float = 1.0,
    y1: float = 1.0,
    limit: int = 8,
) -> dict:
    """Screenshot and OCR. Returns 0-1 centroid of the best match for query (e.g. Face ID & Passcode). No vision-model round-trip."""
    result, path = _capture()
    hit = run_ctl(
        "ocr",
        "--image",
        path,
        "--query",
        query,
        "--x0",
        str(x0),
        "--y0",
        str(y0),
        "--x1",
        str(x1),
        "--y1",
        str(y1),
        "--limit",
        str(max(1, min(32, limit))),
    )
    hit["iphoneInUse"] = result.get("iphoneInUse")
    hit["sha256"] = result.get("sha256")
    return hit


@mcp.tool()
def tap_label(
    query: str,
    mode: Mode = "skylight",
    settle_ms: int = 300,
    x0: float = 0.0,
    y0: float = 0.0,
    x1: float = 1.0,
    y1: float = 1.0,
) -> list:
    """OCR the current screen for query and tap the match. Use this instead of screenshot → guess y → tap."""
    hit = find_text(query, x0=x0, y0=y0, x1=x1, y1=y1, limit=8)
    if not hit.get("found") or hit.get("cx") is None or hit.get("cy") is None:
        result, path = _capture()
        result["tap"] = {
            "ok": False,
            "error": "label not found",
            "query": query,
            "matches": hit.get("matches") or [],
        }
        result["ocr"] = hit
        return _image_payload(result, path)
    seen = tap_and_see(float(hit["cx"]), float(hit["cy"]), mode=mode, settle_ms=settle_ms)
    if seen and isinstance(seen[0], dict):
        seen[0]["ocr"] = {
            "query": query,
            "text": hit.get("text"),
            "cx": hit.get("cx"),
            "cy": hit.get("cy"),
            "confidence": hit.get("confidence"),
        }
    return seen


@mcp.tool()
def scroll(
    delta: int = -12,
    ticks: int = 8,
    x: float = 0.5,
    y: float = 0.55,
) -> dict:
    """Scroll a list under the pointer. Negative delta shows items below (Settings, history). Drag-swipe does not work."""
    status = run_ctl("status")
    px, py = _map_point(x, y, status)
    return run_ctl(
        "scroll",
        "--x",
        str(px),
        "--y",
        str(py),
        "--delta",
        str(delta),
        "--ticks",
        str(ticks),
    )


@mcp.tool()
def type_text(text: str, mode: Mode = "hid") -> dict:
    """Type into the focused iOS field. Prefer ASCII. Newline sends Return (opens Spotlight Top Hit)."""
    return run_ctl("type", "--text", text, "--mode", mode)


@mcp.tool()
def press_key(name: str, mode: Mode = "hid") -> dict:
    """Press a named key on the phone: return, escape, tab, delete, space, up, down, left, right."""
    return run_ctl("key", "--name", name, "--mode", mode)


@mcp.tool()
def press_return(mode: Mode = "hid") -> dict:
    """Press Return. Use after Spotlight search to open the Top Hit."""
    return run_ctl("key", "--name", "return", "--mode", mode)


@mcp.tool()
def open_app(name: str) -> dict:
    """Open an installed iOS app via Spotlight (View menu + type + Return). More reliable than tapping a home icon."""
    spotlight = run_ctl("menu", "--action", "spotlight")
    time.sleep(0.45)
    typed = run_ctl("type", "--text", name, "--mode", "hid")
    time.sleep(0.7)
    entered = run_ctl("key", "--name", "return", "--mode", "hid")
    return {"ok": True, "app": name, "spotlight": spotlight, "typed": typed, "return": entered}


@mcp.tool()
def press_home() -> dict:
    """iPhone Mirroring → View → Home Screen. Leaves the current app. Prefer open_app to launch something."""
    return run_ctl("menu", "--action", "home")


@mcp.tool()
def press_app_switcher() -> dict:
    """iPhone Mirroring → View → App Switcher. Tapping a card in the switcher is unreliable; prefer open_app."""
    return run_ctl("menu", "--action", "app_switcher")


@mcp.tool()
def press_spotlight() -> dict:
    """iPhone Mirroring → View → Spotlight. Then type_text the app name and press_return."""
    return run_ctl("menu", "--action", "spotlight")


def main() -> None:
    mcp.run(transport="stdio")
