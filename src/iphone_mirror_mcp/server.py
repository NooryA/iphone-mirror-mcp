from __future__ import annotations

import os
import tempfile
import time
from typing import Literal

from mcp.server.mcpserver import Image, MCPServer

from iphone_mirror_mcp.ctl import run_ctl, titlebar_pt
from iphone_mirror_mcp.geometry import Rect, assert_inside_window, content_rect, normalized_to_global

mcp = MCPServer(
    "iphone-mirror",
    instructions=(
        "Drive a physical iPhone through the macOS iPhone Mirroring window. "
        "Coordinates are 0-1, origin top-left of the phone content in the screenshot "
        "(Mac title bar is already cropped). "
        "Default tap/swipe/type to hid — iPhone Mirroring ignores postToPid mouse events. "
        "HID briefly moves the Mac cursor onto the window, then restores it. "
        "Never flip Y. Never use press_home to open an app (use open_app). "
        "Always screenshot after a gesture and confirm the iOS UI actually changed "
        "before the next step. If a tap no-ops, retry once at the same coords, then "
        "try Spotlight/open_app or press_return. AX clicks on the Mac hosting view "
        "are not iOS touches."
    ),
)

Mode = Literal["background", "hid"]


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


@mcp.tool()
def mirror_status() -> dict:
    """Return whether iPhone Mirroring is running, window bounds, and Accessibility status."""
    return run_ctl("status")


@mcp.tool()
def mirror_screenshot() -> list:
    """Capture the phone content (Mac title bar cropped). width/height match the PNG in points."""
    fd, path = tempfile.mkstemp(prefix="iphone-mirror-", suffix=".png")
    os.close(fd)
    result = run_ctl("screenshot", "--out", path)
    return [result, Image(path=path)]


@mcp.tool()
def tap(x: float, y: float, mode: Mode = "hid") -> dict:
    """Tap the phone screen. x and y are 0-1, origin top-left of the screenshot / phone content.

    Default hid: warp the real cursor, post an NSEvent click, restore the cursor.
    background (postToPid) is ignored by iPhone Mirroring for mouse; do not use it first.
    """
    status = run_ctl("status")
    px, py = _map_point(x, y, status)
    return run_ctl("tap", "--x", str(px), "--y", str(py), "--mode", mode)


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
def type_text(text: str, mode: Mode = "hid") -> dict:
    """Type into the focused iOS field. Prefer ASCII. Newline sends Return (opens Spotlight Top Hit)."""
    return run_ctl("type", "--text", text, "--mode", mode)


@mcp.tool()
def press_key(name: str, mode: Mode = "hid") -> dict:
    """Press a named key on the phone: return, escape, tab, delete, space."""
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
