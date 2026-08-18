from __future__ import annotations

import json
import math
import os
import string
import tempfile
import time
from collections.abc import Iterator
from contextlib import contextmanager
from pathlib import Path
from typing import Annotated, Any, Literal

from mcp.server.mcpserver import Image, MCPServer
from mcp.types import CallToolResult, TextContent, ToolAnnotations

from iphone_mirror_mcp.ctl import run_ctl
from iphone_mirror_mcp.screen import (
    annotate_screenshot,
    blocked_reason_from_ocr,
    find_pixels,
    visual_hash_distance,
    visual_signature_distance,
)

mcp = MCPServer(
    "iphone-mirror",
    instructions=(
        "Drive a physical iPhone through the macOS iPhone Mirroring window. "
        "Coordinates are 0-1, origin top-left of the phone content in the screenshot "
        "(Mac title bar is cropped; the iOS status bar remains). Never flip Y. "
        "Taps default to skylight, the compatibility name for a cliclick pointer action "
        "with an orange overlay. Text typing defaults to HID/cliclick. Drag-swipe and "
        "named-key compatibility tools fail closed because those events do not reach iOS. "
        "Prefer tap_label/find_text for visible words and scroll for iOS lists. "
        "Prefer tap_and_see and wait_for_change over blind sleeps. Pass the most recent "
        "sha256 as expected_sha256 for state-sensitive actions. If interactionBlocked is true, "
        "do not interact; resolve the reported host state first. Use open_app instead of Home icons. "
        "AX clicks on the Mac hosting view are not iOS touches."
    ),
)

Mode = Literal["background", "hid", "skylight"]

MAX_SETTLE_MS = 10_000
MAX_WAIT_MS = 60_000
MAX_SWIPE_MS = 5_000
MAX_TEXT_LENGTH = 4_000
MAX_SCROLL_DELTA = 120
MAX_SCROLL_TICKS = 40
MAX_VISUAL_HASH_DISTANCE = 8
MAX_VISUAL_SIGNATURE_DISTANCE = 6.0

ImageToolResult = Annotated[CallToolResult, dict[str, Any]]

READ_ONLY_TOOL = ToolAnnotations(
    readOnlyHint=True,
    destructiveHint=False,
    idempotentHint=True,
    openWorldHint=False,
)
INPUT_TOOL = ToolAnnotations(
    readOnlyHint=False,
    destructiveHint=True,
    idempotentHint=False,
    openWorldHint=True,
)


def _bounded_int(value: int, *, name: str, minimum: int, maximum: int) -> int:
    if isinstance(value, bool) or not isinstance(value, int):
        raise TypeError(f"{name} must be an integer")
    if value < minimum or value > maximum:
        raise ValueError(f"{name} must be between {minimum} and {maximum}")
    return value


def _bounded_number(value: float, *, name: str, minimum: float, maximum: float) -> float:
    if isinstance(value, bool) or not isinstance(value, (int, float)) or not math.isfinite(value):
        raise ValueError(f"{name} must be a finite number")
    numeric = float(value)
    if numeric < minimum or numeric > maximum:
        raise ValueError(f"{name} must be between {minimum} and {maximum}")
    return numeric


def _validate_region(x0: float, y0: float, x1: float, y1: float) -> tuple[float, float, float, float]:
    left = _bounded_number(x0, name="x0", minimum=0, maximum=1)
    top = _bounded_number(y0, name="y0", minimum=0, maximum=1)
    right = _bounded_number(x1, name="x1", minimum=0, maximum=1)
    bottom = _bounded_number(y1, name="y1", minimum=0, maximum=1)
    if left >= right or top >= bottom:
        raise ValueError("region must satisfy x0 < x1 and y0 < y1")
    return left, top, right, bottom


def _validate_expected_sha256(expected_sha256: str | None) -> str | None:
    if expected_sha256 is None:
        return None
    value = expected_sha256.strip().lower()
    if len(value) != 64 or any(character not in string.hexdigits for character in value):
        raise ValueError("expected_sha256 must be a 64-character hexadecimal SHA-256")
    return value


@contextmanager
def _capture_file() -> Iterator[tuple[dict[str, Any], str]]:
    """Capture to a short-lived file and always remove it after the tool result is materialized."""
    fd, path = tempfile.mkstemp(prefix="iphone-mirror-", suffix=".png")
    os.close(fd)
    try:
        result = run_ctl("screenshot", "--out", path)
        result.pop("path", None)
        annotate_screenshot(result, path)
        yield result, path
    finally:
        try:
            os.unlink(path)
        except FileNotFoundError:
            pass


@contextmanager
def _output_file() -> Iterator[str]:
    fd, path = tempfile.mkstemp(prefix="iphone-mirror-", suffix=".png")
    os.close(fd)
    try:
        yield path
    finally:
        try:
            os.unlink(path)
        except FileNotFoundError:
            pass


def _image_payload(result: dict[str, Any], path: str) -> CallToolResult:
    if "interactionBlocked" not in result:
        _annotate_interaction_state(result, path)
    metadata = dict(result)
    return CallToolResult(
        content=[
            TextContent(type="text", text=json.dumps(metadata, sort_keys=True)),
            Image(data=Path(path).read_bytes(), format="png").to_image_content(),
        ],
        structuredContent=metadata,
    )


def _annotate_interaction_state(screen: dict[str, Any], path: str) -> str | None:
    ocr = run_ctl("ocr", "--image", path, "--query", "", "--limit", "32")
    blocked_reason = blocked_reason_from_ocr(
        list(ocr.get("matches") or []),
        iphone_in_use=bool(screen.get("iphoneInUseHeuristic")),
    )
    screen["iphoneInUse"] = blocked_reason == "iphone_in_use"
    screen["interactionBlocked"] = blocked_reason is not None
    screen["blockedReason"] = blocked_reason
    return blocked_reason


def _attach_screen_state(result: dict[str, Any], screen: dict[str, Any]) -> dict[str, Any]:
    for key in (
        "sha256",
        "visualHash",
        "visualSignature",
        "iphoneInUse",
        "iphoneInUseHeuristic",
        "interactionBlocked",
        "blockedReason",
    ):
        result[key] = screen.get(key)
    return result


def _expected_args(expected_sha256: str | None) -> tuple[str, ...]:
    expected = _validate_expected_sha256(expected_sha256)
    return ("--expected-sha256", expected) if expected is not None else ()


def _visual_changed(
    baseline_hash: str,
    current_hash: str,
    baseline_signature: str,
    current_signature: str,
) -> tuple[bool, int, float]:
    hash_distance = visual_hash_distance(baseline_hash, current_hash)
    signature_distance = visual_signature_distance(baseline_signature, current_signature)
    changed = hash_distance > MAX_VISUAL_HASH_DISTANCE or signature_distance > MAX_VISUAL_SIGNATURE_DISTANCE
    return changed, hash_distance, signature_distance


@mcp.tool(annotations=READ_ONLY_TOOL)
def mirror_status() -> dict[str, Any]:
    """Return app/window visibility, bounds, display mapping, permissions, and capabilities."""
    return run_ctl("status")


@mcp.tool(annotations=READ_ONLY_TOOL)
def mirror_doctor() -> dict[str, Any]:
    """Diagnose macOS version, permissions, dependencies, displays, and native backends."""
    return run_ctl("doctor")


@mcp.tool(annotations=READ_ONLY_TOOL)
def mirror_screenshot() -> ImageToolResult:
    """Capture phone content. The result includes dimensions, sha256, and iphoneInUse."""
    with _capture_file() as (result, path):
        return _image_payload(result, path)


@mcp.tool(annotations=INPUT_TOOL)
def tap(
    x: float,
    y: float,
    mode: Mode = "skylight",
    expected_sha256: str | None = None,
) -> dict[str, Any]:
    """Tap 0-1 phone-content coordinates after a disconnected/stale-screen safety check."""
    return _tap(x, y, mode, expected_sha256=expected_sha256)


def _tap(
    x: float,
    y: float,
    mode: Mode,
    *,
    expected_sha256: str | None = None,
) -> dict[str, Any]:
    nx = _bounded_number(x, name="x", minimum=0, maximum=1)
    ny = _bounded_number(y, name="y", minimum=0, maximum=1)
    return run_ctl(
        "tap-normalized",
        "--x",
        str(nx),
        "--y",
        str(ny),
        "--mode",
        mode,
        *_expected_args(expected_sha256),
    )


@mcp.tool(annotations=INPUT_TOOL)
def tap_and_see(
    x: float,
    y: float,
    mode: Mode = "skylight",
    settle_ms: int = 300,
    expected_sha256: str | None = None,
) -> ImageToolResult:
    """Safely tap, wait up to 10 seconds, then return the resulting screenshot."""
    return _tap_and_see(
        x,
        y,
        mode,
        settle_ms,
        expected_sha256=expected_sha256,
    )


def _tap_and_see(
    x: float,
    y: float,
    mode: Mode,
    settle_ms: int,
    *,
    expected_sha256: str | None = None,
    expected_image_path: str | None = None,
    ocr_metadata: dict[str, Any] | None = None,
) -> CallToolResult:
    settle = _bounded_int(settle_ms, name="settle_ms", minimum=0, maximum=MAX_SETTLE_MS)
    nx = _bounded_number(x, name="x", minimum=0, maximum=1)
    ny = _bounded_number(y, name="y", minimum=0, maximum=1)
    expected_image_args = ("--expected-image", expected_image_path) if expected_image_path else ()
    with _output_file() as path:
        result = run_ctl(
            "tap-and-capture",
            "--x",
            str(nx),
            "--y",
            str(ny),
            "--mode",
            mode,
            "--settle-ms",
            str(settle),
            "--out",
            path,
            *_expected_args(expected_sha256),
            *expected_image_args,
        )
        result.pop("path", None)
        annotate_screenshot(result, path)
        if ocr_metadata is not None:
            result["ocr"] = ocr_metadata
        return _image_payload(result, path)


@mcp.tool(annotations=INPUT_TOOL)
def swipe(
    x1: float,
    y1: float,
    x2: float,
    y2: float,
    duration_ms: int = 180,
    mode: Mode = "hid",
    expected_sha256: str | None = None,
) -> dict[str, Any]:
    """Compatibility endpoint that fails closed; iPhone Mirroring ignores drag swipes."""
    duration = _bounded_int(duration_ms, name="duration_ms", minimum=80, maximum=MAX_SWIPE_MS)
    start_x = _bounded_number(x1, name="x1", minimum=0, maximum=1)
    start_y = _bounded_number(y1, name="y1", minimum=0, maximum=1)
    end_x = _bounded_number(x2, name="x2", minimum=0, maximum=1)
    end_y = _bounded_number(y2, name="y2", minimum=0, maximum=1)
    return run_ctl(
        "swipe",
        "--x1",
        str(start_x),
        "--y1",
        str(start_y),
        "--x2",
        str(end_x),
        "--y2",
        str(end_y),
        "--duration-ms",
        str(duration),
        "--mode",
        mode,
        *_expected_args(expected_sha256),
    )


@mcp.tool(annotations=READ_ONLY_TOOL)
def wait_for_change(timeout_ms: int = 8_000, interval_ms: int = 400) -> ImageToolResult:
    """Poll until the perceptual screen hash changes materially or a bounded timeout expires."""
    timeout = _bounded_int(timeout_ms, name="timeout_ms", minimum=0, maximum=MAX_WAIT_MS)
    interval = _bounded_int(interval_ms, name="interval_ms", minimum=50, maximum=5_000)
    with _capture_file() as (baseline, baseline_path):
        _annotate_interaction_state(baseline, baseline_path)
        baseline_hash = str(baseline.get("sha256") or "")
        baseline_visual_hash = str(baseline.get("visualHash") or "")
        baseline_visual_signature = str(baseline.get("visualSignature") or "")
        if baseline.get("interactionBlocked") or timeout == 0:
            baseline["changed"] = False
            baseline["sha256Changed"] = False
            baseline["visualHashDistance"] = 0
            baseline["visualSignatureDistance"] = 0.0
            baseline["timedOut"] = timeout == 0 and not baseline.get("interactionBlocked")
            baseline["elapsedMs"] = 0
            return _image_payload(baseline, baseline_path)

    started = time.monotonic()
    while True:
        elapsed_ms = int((time.monotonic() - started) * 1_000)
        if elapsed_ms < timeout:
            time.sleep(min(interval, timeout - elapsed_ms) / 1000.0)
        with _capture_file() as (result, path):
            _annotate_interaction_state(result, path)
            elapsed_ms = int((time.monotonic() - started) * 1_000)
            sha256_changed = str(result.get("sha256") or "") != baseline_hash
            changed, hash_distance, signature_distance = _visual_changed(
                baseline_visual_hash,
                str(result.get("visualHash") or ""),
                baseline_visual_signature,
                str(result.get("visualSignature") or ""),
            )
            if result.get("interactionBlocked") or changed or elapsed_ms >= timeout:
                result["changed"] = changed
                result["sha256Changed"] = sha256_changed
                result["visualHashDistance"] = hash_distance
                result["visualSignatureDistance"] = signature_distance
                result["timedOut"] = not changed and not result.get("interactionBlocked")
                result["elapsedMs"] = elapsed_ms
                return _image_payload(result, path)


@mcp.tool(annotations=READ_ONLY_TOOL)
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
) -> dict[str, Any]:
    """Return the centroid of pixels near an RGB color inside a validated region."""
    red = _bounded_int(r, name="r", minimum=0, maximum=255)
    green = _bounded_int(g, name="g", minimum=0, maximum=255)
    blue = _bounded_int(b, name="b", minimum=0, maximum=255)
    delta = _bounded_int(tolerance, name="tolerance", minimum=0, maximum=255)
    minimum = _bounded_int(min_pixels, name="min_pixels", minimum=1, maximum=1_000_000)
    region = _validate_region(x0, y0, x1, y1)
    with _capture_file() as (result, path):
        _annotate_interaction_state(result, path)
        hit = find_pixels(
            path,
            red=red,
            green=green,
            blue=blue,
            tolerance=delta,
            x0=region[0],
            y0=region[1],
            x1=region[2],
            y1=region[3],
            min_pixels=minimum,
        )
    return _attach_screen_state(hit, result)


@mcp.tool(annotations=READ_ONLY_TOOL)
def find_bright(
    min_lum: int = 200,
    x0: float = 0.0,
    y0: float = 0.0,
    x1: float = 1.0,
    y1: float = 1.0,
    min_pixels: int = 20,
) -> dict[str, Any]:
    """Return the centroid of bright pixels inside a validated region."""
    luminance = _bounded_int(min_lum, name="min_lum", minimum=0, maximum=255)
    minimum = _bounded_int(min_pixels, name="min_pixels", minimum=1, maximum=1_000_000)
    region = _validate_region(x0, y0, x1, y1)
    with _capture_file() as (result, path):
        _annotate_interaction_state(result, path)
        hit = find_pixels(
            path,
            min_lum=luminance,
            x0=region[0],
            y0=region[1],
            x1=region[2],
            y1=region[3],
            min_pixels=minimum,
        )
    return _attach_screen_state(hit, result)


@mcp.tool(annotations=READ_ONLY_TOOL)
def find_text(
    query: str,
    x0: float = 0.0,
    y0: float = 0.0,
    x1: float = 1.0,
    y1: float = 1.0,
    limit: int = 8,
) -> dict[str, Any]:
    """Screenshot and use local Vision OCR to locate a visible label."""
    query, region, cap = _validated_text_search(query, x0, y0, x1, y1, limit)
    with _capture_file() as (result, path):
        _annotate_interaction_state(result, path)
        hit = _find_text_in_capture(query, region, cap, path)
    return _attach_screen_state(hit, result)


def _validated_text_search(
    query: str,
    x0: float,
    y0: float,
    x1: float,
    y1: float,
    limit: int,
) -> tuple[str, tuple[float, float, float, float], int]:
    if not query.strip():
        raise ValueError("query must not be empty")
    if len(query) > 500:
        raise ValueError("query must be at most 500 characters")
    if "\0" in query:
        raise ValueError("query must not contain NUL characters")
    region = _validate_region(x0, y0, x1, y1)
    cap = _bounded_int(limit, name="limit", minimum=1, maximum=32)
    return query, region, cap


def _find_text_in_capture(
    query: str,
    region: tuple[float, float, float, float],
    limit: int,
    path: str,
) -> dict[str, Any]:
    return run_ctl(
        "ocr",
        "--image",
        path,
        "--query",
        query,
        "--x0",
        str(region[0]),
        "--y0",
        str(region[1]),
        "--x1",
        str(region[2]),
        "--y1",
        str(region[3]),
        "--limit",
        str(limit),
    )


@mcp.tool(annotations=INPUT_TOOL)
def tap_label(
    query: str,
    mode: Mode = "skylight",
    settle_ms: int = 300,
    x0: float = 0.0,
    y0: float = 0.0,
    x1: float = 1.0,
    y1: float = 1.0,
) -> ImageToolResult:
    """OCR, verify that the observed frame is still current, tap the label, and screenshot."""
    query, region, cap = _validated_text_search(query, x0, y0, x1, y1, 8)
    with _capture_file() as (source, source_path):
        _annotate_interaction_state(source, source_path)
        hit = _attach_screen_state(
            _find_text_in_capture(query, region, cap, source_path),
            source,
        )
        if not hit.get("found") or hit.get("cx") is None or hit.get("cy") is None:
            result = dict(source)
            result["tap"] = {
                "ok": False,
                "error": "label not found",
                "query": query,
                "matches": hit.get("matches") or [],
            }
            result["ocr"] = hit
            return _image_payload(result, source_path)
        return _tap_and_see(
            float(hit["cx"]),
            float(hit["cy"]),
            mode=mode,
            settle_ms=settle_ms,
            expected_image_path=source_path,
            ocr_metadata={
                "query": query,
                "text": hit.get("text"),
                "cx": hit.get("cx"),
                "cy": hit.get("cy"),
                "confidence": hit.get("confidence"),
            },
        )


@mcp.tool(annotations=INPUT_TOOL)
def scroll(
    delta: int = -12,
    ticks: int = 8,
    x: float = 0.5,
    y: float = 0.55,
    expected_sha256: str | None = None,
) -> dict[str, Any]:
    """HID scroll-wheel over the phone after validating pointer placement and screen state."""
    wheel = _bounded_int(delta, name="delta", minimum=-MAX_SCROLL_DELTA, maximum=MAX_SCROLL_DELTA)
    count = _bounded_int(ticks, name="ticks", minimum=1, maximum=MAX_SCROLL_TICKS)
    nx = _bounded_number(x, name="x", minimum=0, maximum=1)
    ny = _bounded_number(y, name="y", minimum=0, maximum=1)
    return run_ctl(
        "scroll-normalized",
        "--x",
        str(nx),
        "--y",
        str(ny),
        "--delta",
        str(wheel),
        "--ticks",
        str(count),
        *_expected_args(expected_sha256),
    )


@mcp.tool(annotations=INPUT_TOOL)
def type_text(
    text: str,
    mode: Mode = "hid",
    expected_sha256: str | None = None,
) -> dict[str, Any]:
    """Type into the focused iOS field after a screen-state safety check."""
    if not text:
        raise ValueError("text must not be empty")
    if len(text) > MAX_TEXT_LENGTH:
        raise ValueError(f"text must be at most {MAX_TEXT_LENGTH} characters")
    if "\n" in text or "\r" in text:
        raise ValueError("text must be a single line; named Return events are not delivered to iOS")
    if "\0" in text:
        raise ValueError("text must not contain NUL characters")
    return run_ctl("type", "--text", text, "--mode", mode, *_expected_args(expected_sha256))


@mcp.tool(annotations=INPUT_TOOL)
def press_key(
    name: str,
    mode: Mode = "hid",
    expected_sha256: str | None = None,
) -> dict[str, Any]:
    """Compatibility endpoint that fails closed; named key events do not reach iOS."""
    return run_ctl("key", "--name", name, "--mode", mode, *_expected_args(expected_sha256))


@mcp.tool(annotations=INPUT_TOOL)
def press_return(
    mode: Mode = "hid",
    expected_sha256: str | None = None,
) -> dict[str, Any]:
    """Compatibility endpoint that fails closed; Return events do not reach iOS."""
    return press_key("return", mode, expected_sha256)


@mcp.tool(annotations=INPUT_TOOL)
def open_app(name: str, expected_sha256: str | None = None) -> dict[str, Any]:
    """Open an installed iOS app through the iPhone Mirroring Spotlight command."""
    app_name = name.strip()
    if not app_name or len(app_name) > 200 or "\n" in app_name or "\r" in app_name:
        raise ValueError("name must be 1-200 characters on one line")
    if "\0" in app_name:
        raise ValueError("name must not contain NUL characters")
    return run_ctl(
        "open-app",
        "--name",
        app_name,
        *_expected_args(expected_sha256),
    )


def _menu_action(action: str, expected_sha256: str | None) -> dict[str, Any]:
    return run_ctl("menu", "--action", action, *_expected_args(expected_sha256))


@mcp.tool(annotations=INPUT_TOOL)
def press_home(expected_sha256: str | None = None) -> dict[str, Any]:
    """Invoke iPhone Mirroring's Home Screen command."""
    return _menu_action("home", expected_sha256)


@mcp.tool(annotations=INPUT_TOOL)
def press_app_switcher(expected_sha256: str | None = None) -> dict[str, Any]:
    """Invoke iPhone Mirroring's App Switcher command."""
    return _menu_action("app_switcher", expected_sha256)


@mcp.tool(annotations=INPUT_TOOL)
def press_spotlight(expected_sha256: str | None = None) -> dict[str, Any]:
    """Invoke iPhone Mirroring's Spotlight command."""
    return _menu_action("spotlight", expected_sha256)


def main() -> None:
    mcp.run(transport="stdio")
