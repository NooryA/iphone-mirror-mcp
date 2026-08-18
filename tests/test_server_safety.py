import base64
import os
import tempfile
from concurrent.futures import ThreadPoolExecutor
from contextlib import contextmanager
from pathlib import Path
from typing import Any

import pytest
from PIL import Image

from iphone_mirror_mcp import server


def _install_fake_native(
    monkeypatch: pytest.MonkeyPatch,
    tmp_path: Path,
    *,
    ocr_matches: list[dict[str, Any]] | None = None,
    label_hit: dict[str, Any] | None = None,
) -> list[tuple[str, ...]]:
    calls: list[tuple[str, ...]] = []
    real_mkstemp = tempfile.mkstemp

    def local_mkstemp(*, prefix: str, suffix: str) -> tuple[int, str]:
        return real_mkstemp(prefix=prefix, suffix=suffix, dir=tmp_path)

    def fake_run_ctl(*args: str, timeout: float = 20.0) -> dict[str, Any]:
        del timeout
        calls.append(args)
        command = args[0]
        if command in {"screenshot", "capture-analyze", "tap-and-capture", "tap-label-and-capture"}:
            output = args[args.index("--out") + 1]
            image = Image.new("RGB", (60, 120), (0, 0, 0))
            for pixel_y in range(120):
                for pixel_x in range(60):
                    if pixel_x >= 50 and pixel_y < 10:
                        image.putpixel((pixel_x, pixel_y), (255, 255, 255))
                    elif (pixel_x + pixel_y) % 5 == 0:
                        image.putpixel((pixel_x, pixel_y), (220, 80, 30))
            image.save(output)
            result = {
                "ok": True,
                "x": 100,
                "y": 148,
                "width": 300,
                "height": 652,
                "contentX": 100,
                "contentY": 200,
                "contentWidth": 300,
                "contentHeight": 600,
            }
            if command == "capture-analyze":
                host_matches = ocr_matches or []
                blocked_reason = server.blocked_reason_from_ocr(host_matches, iphone_in_use=False)
                result.update(
                    {
                        "iphoneInUse": blocked_reason == "iphone_in_use",
                        "interactionBlocked": blocked_reason is not None,
                        "blockedReason": blocked_reason,
                    }
                )
                if "--query" in args:
                    query = args[args.index("--query") + 1]
                    matches = [label_hit] if label_hit else []
                    result["ocr"] = {
                        "ok": True,
                        "query": query,
                        "found": bool(matches),
                        "matches": matches,
                        **(label_hit or {}),
                    }
            if command == "tap-and-capture":
                result["command"] = command
                result["preflightSha256"] = "a" * 64
                result["tap"] = {"ok": True}
                result["screenChanged"] = True
                result["visualDistanceFromPreflight"] = 12.0
                result.update({"iphoneInUse": False, "interactionBlocked": False, "blockedReason": None})
            if command == "tap-label-and-capture":
                query = args[args.index("--query") + 1]
                matches = [label_hit] if label_hit else []
                result["command"] = command
                result["atomicLabelSelection"] = True
                result["tap"] = {"ok": bool(matches)}
                result["screenChanged"] = bool(matches)
                result["visualDistanceFromPreflight"] = 12.0 if matches else 0.0
                if not matches:
                    result["tap"].update({"error": "label not found", "query": query, "matches": []})
                result["ocr"] = {
                    "query": query,
                    "found": bool(matches),
                    "matches": matches,
                    **(label_hit or {}),
                }
                result.update({"iphoneInUse": False, "interactionBlocked": False, "blockedReason": None})
            return result
        if command == "ocr":
            query = args[args.index("--query") + 1]
            matches = ocr_matches or [] if not query else ([label_hit] if label_hit else [])
            result = {"ok": True, "found": bool(matches), "matches": matches}
            if matches:
                result.update(matches[0])
            return result
        if command == "status":
            return {
                "ok": True,
                "running": True,
                "windowVisible": True,
                "x": 100,
                "y": 148,
                "width": 300,
                "height": 652,
                "contentX": 100,
                "contentY": 200,
                "contentWidth": 300,
                "contentHeight": 600,
            }
        if command == "open-app":
            return {"ok": True, "command": command, "app": args[args.index("--name") + 1]}
        return {"ok": True, "command": command, "preflightSha256": "a" * 64}

    monkeypatch.setattr(server.tempfile, "mkstemp", local_mkstemp)
    monkeypatch.setattr(server, "run_ctl", fake_run_ctl)
    return calls


def _metadata(payload: Any) -> dict[str, Any]:
    assert payload.is_error is False
    assert payload.structured_content is not None
    return payload.structured_content


def test_capture_file_is_removed_after_success(monkeypatch: pytest.MonkeyPatch, tmp_path: Path) -> None:
    _install_fake_native(monkeypatch, tmp_path)
    with server._capture_file() as (result, path):
        assert result["ok"] is True
        assert Path(path).is_file()
    assert not Path(path).exists()
    assert list(tmp_path.iterdir()) == []


def test_capture_file_is_removed_after_native_error(monkeypatch: pytest.MonkeyPatch, tmp_path: Path) -> None:
    real_mkstemp = tempfile.mkstemp
    paths: list[str] = []

    def local_mkstemp(*, prefix: str, suffix: str) -> tuple[int, str]:
        descriptor, path = real_mkstemp(prefix=prefix, suffix=suffix, dir=tmp_path)
        paths.append(path)
        return descriptor, path

    monkeypatch.setattr(server.tempfile, "mkstemp", local_mkstemp)
    monkeypatch.setattr(server, "run_ctl", lambda *args: (_ for _ in ()).throw(RuntimeError("boom")))
    with pytest.raises(RuntimeError, match="boom"), server._capture_file():
        pass
    assert paths and all(not Path(path).exists() for path in paths)


def test_image_payload_survives_temp_cleanup(monkeypatch: pytest.MonkeyPatch, tmp_path: Path) -> None:
    _install_fake_native(monkeypatch, tmp_path)
    payload = server.mirror_screenshot()
    assert _metadata(payload)["pngWidth"] == 60
    assert payload.content[1].type == "image"
    assert base64.b64decode(payload.content[1].data).startswith(b"\x89PNG")
    assert list(tmp_path.iterdir()) == []


def test_visual_helpers_report_host_blocking_state(
    monkeypatch: pytest.MonkeyPatch,
    tmp_path: Path,
) -> None:
    _install_fake_native(monkeypatch, tmp_path, ocr_matches=[{"text": "iCloud Signed Out"}])
    result = server.find_bright(min_pixels=1)
    assert result["interactionBlocked"] is True
    assert result["blockedReason"] == "icloud_signed_out"


def test_wait_for_change_uses_visual_distance(
    monkeypatch: pytest.MonkeyPatch,
    tmp_path: Path,
) -> None:
    _install_fake_native(monkeypatch, tmp_path)
    baseline_path = tmp_path / "baseline.png"
    changed_path = tmp_path / "changed.png"
    baseline = Image.new("RGB", (64, 128))
    changed = Image.new("RGB", (64, 128))
    for x in range(64):
        level = int(x * 255 / 63)
        for y in range(128):
            baseline.putpixel((x, y), (level, level, level))
            changed.putpixel((x, y), (255 - level, 255 - level, 255 - level))
    baseline.save(baseline_path)
    changed.save(changed_path)
    capture_count = 0

    @contextmanager
    def fake_capture() -> Any:
        nonlocal capture_count
        path = baseline_path if capture_count == 0 else changed_path
        capture_count += 1
        result: dict[str, Any] = {"ok": True}
        server.annotate_screenshot(result, str(path))
        yield result, str(path)

    monkeypatch.setattr(server, "_capture_file", fake_capture)
    monkeypatch.setattr(server.time, "sleep", lambda _: None)
    payload = server.wait_for_change(timeout_ms=1_000, interval_ms=50)
    result = _metadata(payload)
    assert result["changed"] is True
    assert result["sha256Changed"] is True
    assert result["visualHashDistance"] > server.MAX_VISUAL_HASH_DISTANCE
    assert result["visualSignatureDistance"] > server.MAX_VISUAL_SIGNATURE_DISTANCE
    assert result["timedOut"] is False


def test_wait_for_change_detects_flat_black_to_white_transition(
    monkeypatch: pytest.MonkeyPatch,
    tmp_path: Path,
) -> None:
    _install_fake_native(monkeypatch, tmp_path)
    baseline_path = tmp_path / "black.png"
    changed_path = tmp_path / "white.png"
    Image.new("RGB", (64, 128), "black").save(baseline_path)
    Image.new("RGB", (64, 128), "white").save(changed_path)
    capture_count = 0

    @contextmanager
    def fake_capture() -> Any:
        nonlocal capture_count
        path = baseline_path if capture_count == 0 else changed_path
        capture_count += 1
        result: dict[str, Any] = {"ok": True}
        server.annotate_screenshot(result, str(path))
        yield result, str(path)

    monkeypatch.setattr(server, "_capture_file", fake_capture)
    monkeypatch.setattr(server.time, "sleep", lambda _: None)
    result = _metadata(server.wait_for_change(timeout_ms=1_000, interval_ms=50))
    assert result["changed"] is True
    assert result["visualHashDistance"] == 0
    assert result["visualSignatureDistance"] == 255


def test_wait_for_change_ignores_insignificant_exact_hash_noise(
    monkeypatch: pytest.MonkeyPatch,
    tmp_path: Path,
) -> None:
    _install_fake_native(monkeypatch, tmp_path)
    baseline_path = tmp_path / "baseline-noise.png"
    noisy_path = tmp_path / "noisy.png"
    baseline = Image.new("L", (90, 80))
    baseline.putdata([int(x * 255 / 89) for _y in range(80) for x in range(90)])
    noisy = baseline.copy()
    noisy.putpixel((4, 4), min(255, noisy.getpixel((4, 4)) + 1))
    baseline.save(baseline_path)
    noisy.save(noisy_path)
    capture_count = 0

    @contextmanager
    def fake_capture() -> Any:
        nonlocal capture_count
        path = baseline_path if capture_count == 0 else noisy_path
        capture_count += 1
        result: dict[str, Any] = {"ok": True}
        server.annotate_screenshot(result, str(path))
        yield result, str(path)

    monotonic_values = iter((0.0, 0.0, 0.1))
    monkeypatch.setattr(server, "_capture_file", fake_capture)
    monkeypatch.setattr(server.time, "monotonic", lambda: next(monotonic_values))
    monkeypatch.setattr(server.time, "sleep", lambda _: None)
    payload = server.wait_for_change(timeout_ms=50, interval_ms=50)
    result = _metadata(payload)
    assert result["changed"] is False
    assert result["sha256Changed"] is True
    assert result["visualHashDistance"] == 0
    assert result["visualSignatureDistance"] <= server.MAX_VISUAL_SIGNATURE_DISTANCE
    assert result["timedOut"] is True


def test_tap_delegates_normalized_mapping_to_atomic_native_command(
    monkeypatch: pytest.MonkeyPatch,
    tmp_path: Path,
) -> None:
    calls = _install_fake_native(monkeypatch, tmp_path)
    result = server.tap(0.5, 0.5)
    tap_call = next(call for call in calls if call[0] == "tap-normalized")
    assert tap_call[tap_call.index("--x") + 1] == "0.5"
    assert tap_call[tap_call.index("--y") + 1] == "0.5"
    assert result["preflightSha256"]
    assert all(call[0] != "screenshot" for call in calls)


@pytest.mark.parametrize(
    ("value", "exception", "error"),
    [
        (-1, ValueError, "between"),
        (60_001, ValueError, "between"),
        (True, TypeError, "integer"),
        (1.5, TypeError, "integer"),
    ],
)
def test_bounded_integer_validation(value: Any, exception: type[Exception], error: str) -> None:
    with pytest.raises(exception, match=error):
        server._bounded_int(value, name="value", minimum=0, maximum=60_000)


@pytest.mark.parametrize(
    "region",
    [(-0.1, 0, 1, 1), (0, 0, 1.1, 1), (0.5, 0, 0.5, 1), (0, 0.7, 1, 0.2)],
)
def test_invalid_regions_are_rejected(region: tuple[float, float, float, float]) -> None:
    with pytest.raises(ValueError):
        server._validate_region(*region)


def test_expected_hash_validation() -> None:
    assert server._validate_expected_sha256("A" * 64) == "a" * 64
    for invalid in ("", "xyz", "g" * 64, "0" * 63):
        with pytest.raises(ValueError, match="SHA-256"):
            server._validate_expected_sha256(invalid)


def test_capture_cleanup_does_not_leave_open_file(monkeypatch: pytest.MonkeyPatch, tmp_path: Path) -> None:
    _install_fake_native(monkeypatch, tmp_path)
    with server._capture_file() as (_, path):
        descriptor = os.open(path, os.O_RDONLY)
        os.close(descriptor)
    assert not Path(path).exists()


def test_all_public_tool_families_dispatch_with_validated_arguments(
    monkeypatch: pytest.MonkeyPatch,
    tmp_path: Path,
) -> None:
    label = {"text": "Settings", "cx": 0.4, "cy": 0.3, "confidence": 0.99}
    calls = _install_fake_native(monkeypatch, tmp_path, label_hit=label)
    monkeypatch.setattr(server.time, "sleep", lambda _: None)

    assert server.mirror_status()["ok"] is True
    assert server.mirror_doctor()["command"] == "doctor"
    assert server.swipe(0.2, 0.8, 0.2, 0.2)["command"] == "swipe"
    assert server.scroll(delta=-5, ticks=3)["command"] == "scroll-normalized"
    assert server.type_text("hello")["command"] == "type"
    assert server.press_key("return")["command"] == "key"
    assert server.press_return()["command"] == "key"
    assert server.open_app("Settings")["app"] == "Settings"
    assert server.press_home()["command"] == "menu"
    assert server.press_app_switcher()["command"] == "menu"
    assert server.press_spotlight()["command"] == "menu"
    assert server.find_color(220, 80, 30, tolerance=0, min_pixels=1)["found"] is True
    assert server.find_bright(min_lum=200, min_pixels=1)["found"] is True
    assert server.find_text("Settings")["text"] == "Settings"
    label_call_start = len(calls)
    tapped = _metadata(server.tap_label("Settings", settle_ms=0))
    assert tapped["ocr"]["text"] == "Settings"
    assert tapped["atomicLabelSelection"] is True
    assert tapped["screenChanged"] is True
    label_tap_call = [call for call in calls if call[0] == "tap-label-and-capture"][-1]
    assert label_tap_call[label_tap_call.index("--query") + 1] == "Settings"
    assert "--expected-image" not in label_tap_call
    label_calls = calls[label_call_start:]
    assert label_calls[0][0] == "tap-label-and-capture"
    assert all(call[0] != "screenshot" for call in label_calls)
    unchanged = _metadata(server.wait_for_change(timeout_ms=0))
    assert unchanged["timedOut"] is True
    assert unchanged["sha256Changed"] is False
    assert unchanged["visualHashDistance"] == 0
    assert unchanged["visualSignatureDistance"] == 0

    dispatched = {call[0] for call in calls}
    assert {
        "status",
        "doctor",
        "swipe",
        "scroll-normalized",
        "type",
        "key",
        "menu",
        "open-app",
        "capture-analyze",
        "tap-label-and-capture",
    } <= dispatched


def test_tap_label_not_found_returns_current_screen(
    monkeypatch: pytest.MonkeyPatch,
    tmp_path: Path,
) -> None:
    _install_fake_native(monkeypatch, tmp_path)
    payload = _metadata(server.tap_label("Missing"))
    assert payload["tap"]["ok"] is False
    assert payload["tap"]["error"] == "label not found"
    assert payload["screenChanged"] is False


@pytest.mark.parametrize("text", ["", "x" * (server.MAX_TEXT_LENGTH + 1), "hello\nworld", "nul\0text"])
def test_invalid_text_is_rejected_before_native_input(text: str) -> None:
    with pytest.raises(ValueError):
        server.type_text(text)


def test_typing_timeout_scales_with_the_bounded_payload() -> None:
    assert server._typing_timeout("short") == 20.0
    assert server._typing_timeout("x" * server.MAX_TEXT_LENGTH) == 215.0


@pytest.mark.parametrize("name", ["", "x" * 201, "Bad\nName", "nul\0name"])
def test_invalid_app_name_is_rejected_before_native_input(name: str) -> None:
    with pytest.raises(ValueError):
        server.open_app(name)


def test_arbitrary_leading_dash_text_is_preserved_for_native_argv(
    monkeypatch: pytest.MonkeyPatch,
    tmp_path: Path,
) -> None:
    calls = _install_fake_native(monkeypatch, tmp_path)
    server.find_text("--query")
    server.type_text("--text")
    server.open_app("--name")
    ocr = [call for call in calls if call[0] == "capture-analyze" and "--query" in call][-1]
    typed = next(call for call in calls if call[0] == "type")
    opened = next(call for call in calls if call[0] == "open-app")
    assert ocr[ocr.index("--query") + 1] == "--query"
    assert typed[typed.index("--text") + 1] == "--text"
    assert opened[opened.index("--name") + 1] == "--name"


def test_two_hundred_concurrent_captures_leave_no_temp_files(
    monkeypatch: pytest.MonkeyPatch,
    tmp_path: Path,
) -> None:
    _install_fake_native(monkeypatch, tmp_path)

    def capture_once(_: int) -> str:
        with server._capture_file() as (result, path):
            assert Path(path).is_file()
            return str(result["sha256"])

    with ThreadPoolExecutor(max_workers=16) as pool:
        hashes = list(pool.map(capture_once, range(200)))
    assert len(hashes) == 200
    assert len(set(hashes)) == 1
    assert list(tmp_path.iterdir()) == []
