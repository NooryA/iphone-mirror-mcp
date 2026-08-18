import json
import subprocess
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

import pytest
from PIL import Image

from iphone_mirror_mcp.ctl import BINARY

ROOT = Path(__file__).resolve().parents[1]


@pytest.fixture(scope="module", autouse=True)
def build_native_helper() -> None:
    subprocess.run([str(ROOT / "scripts" / "build-native.sh")], check=True)
    assert BINARY.is_file()


def _run(*args: str) -> tuple[subprocess.CompletedProcess[str], dict]:
    process = subprocess.run([str(BINARY), *args], capture_output=True, text=True, check=False, timeout=20)
    line = process.stdout.strip().splitlines()[-1]
    return process, json.loads(line)


def test_status_is_non_failing_even_when_window_is_not_visible() -> None:
    process, payload = _run("status")
    assert process.returncode == 0
    assert payload["ok"] is True
    assert isinstance(payload["running"], bool)
    assert isinstance(payload["windowVisible"], bool)
    assert isinstance(payload["screenCaptureAllowed"], bool)
    if payload["windowVisible"]:
        assert "welcome" not in payload["windowName"].casefold()
        assert payload["displayScale"] > 0
        assert payload["contentWidth"] > 0
        assert payload["contentHeight"] > 0


def test_doctor_reports_dependencies_displays_and_warnings() -> None:
    process, payload = _run("doctor")
    assert process.returncode == 0
    assert payload["ok"] is True
    assert isinstance(payload["healthy"], bool)
    assert isinstance(payload["displays"], list)
    assert payload["architecture"] in {"arm64", "x86_64", "unknown"}
    assert isinstance(payload["notes"], list)
    assert isinstance(payload["warnings"], list)


def test_native_self_test_covers_window_selection_and_coordinate_round_trip() -> None:
    process, payload = _run("self-test")
    assert process.returncode == 0
    assert payload["ok"] is True
    assert payload["selectedWindowId"] == 3
    for check in (
        "windowSelection",
        "coordinateRoundTrip",
        "cliclickNegativeCoordinates",
        "cliclickHalfOpenEdges",
        "cliclickExplicitTarget",
        "midActionPointerGuard",
        "midScrollAbort",
        "activationGate",
        "typingChunking",
        "dependencyPreflight",
        "argumentParser",
        "argumentParserRejectsInvalid",
        "visualComparison",
        "spotlightResultSelection",
        "spotlightEntryDetection",
        "normalizedWindowRemap",
        "preparedWindowIdentity",
        "captureTimeoutIsolation",
        "windowOnlyCaptureFallback",
        "hostBlockerDetection",
    ):
        assert payload[check] is True


@pytest.mark.parametrize("value", ["", "--definitely-not-text", "-", "a:b", "日本語🙂", "--limit"])
def test_native_parser_preserves_arbitrary_flag_values(tmp_path: Path, value: str) -> None:
    image = tmp_path / "blank.png"
    Image.new("RGB", (32, 32), (0, 0, 0)).save(image)
    process, payload = _run(
        "ocr",
        "--image",
        str(image),
        "--query",
        value,
        "--limit",
        "1",
    )
    assert process.returncode == 0
    assert payload["query"] == value


@pytest.mark.parametrize(
    ("args", "message"),
    [
        (("screenshot", "--unknown", "value"), "unknown flag"),
        (("screenshot", "--out", "one", "--out", "two"), "duplicate flag"),
        (("screenshot", "--out"), "missing value"),
        (("status", "positional"), "expected a --flag"),
    ],
)
def test_native_parser_rejects_invalid_flags(args: tuple[str, ...], message: str) -> None:
    process, payload = _run(*args)
    assert process.returncode == 1
    assert payload["ok"] is False
    assert message in payload["error"]


def test_unknown_input_mode_is_rejected_before_any_pointer_action() -> None:
    process, payload = _run("tap", "--x", "0", "--y", "0", "--mode", "surprise")
    assert process.returncode == 1
    assert payload == {"error": "unknown input mode: surprise", "ok": False}


@pytest.mark.parametrize("bad", ["nan", "inf", "-inf", "not-a-number"])
def test_non_finite_native_coordinates_are_rejected(bad: str) -> None:
    process, payload = _run("tap", "--x", bad, "--y", "0.5")
    assert process.returncode == 1
    assert payload["ok"] is False
    assert "finite" in payload["error"]


def test_unknown_command_is_json_error() -> None:
    process, payload = _run("definitely-not-a-command")
    assert process.returncode == 1
    assert payload["ok"] is False
    assert payload["error"] == "unknown command: definitely-not-a-command"


def test_native_swipe_fails_closed_instead_of_reporting_a_false_success() -> None:
    process, payload = _run(
        "swipe",
        "--x1",
        "0.2",
        "--y1",
        "0.8",
        "--x2",
        "0.2",
        "--y2",
        "0.2",
    )
    assert process.returncode == 1
    assert payload["ok"] is False
    assert "use scroll" in payload["error"]


def test_native_named_key_fails_closed_instead_of_reporting_a_false_success() -> None:
    process, payload = _run("key", "--name", "return")
    assert process.returncode == 1
    assert payload["ok"] is False
    assert "not delivered to iOS" in payload["error"]


def test_native_type_rejects_newline_as_an_unsupported_return_event() -> None:
    process, payload = _run("type", "--text", "hello\n")
    assert process.returncode == 1
    assert payload["ok"] is False
    assert "single line" in payload["error"]


@pytest.mark.parametrize("command", ["tap", "type"])
def test_native_background_mode_fails_closed(command: str) -> None:
    args = ("--x", "0", "--y", "0") if command == "tap" else ("--text", "hello")
    process, payload = _run(command, *args, "--mode", "background")
    assert process.returncode == 1
    assert payload["ok"] is False
    assert "not delivered to iOS" in payload["error"]


@pytest.mark.parametrize("name", ["", "x" * 201, "bad\nname"])
def test_native_open_app_rejects_invalid_names_before_input(name: str) -> None:
    process, payload = _run("open-app", "--name", name)
    assert process.returncode == 1
    assert payload["ok"] is False
    assert "app name" in payload["error"]


@pytest.mark.parametrize(
    ("args", "message"),
    [
        (("--query", "", "--out", "/tmp/out.png"), "1-500 character"),
        (("--query", "Continue"), "requires --out"),
        (("--query", "Continue", "--out", "/tmp/out.png", "--x0", "0.9", "--x1", "0.1"), "x0 < x1"),
    ],
)
def test_native_tap_label_validation_does_not_require_a_phone_window(
    args: tuple[str, ...],
    message: str,
) -> None:
    process, payload = _run("tap-label-and-capture", *args)
    assert process.returncode == 1
    assert payload["ok"] is False
    assert message in payload["error"]


def test_one_hundred_concurrent_status_processes_return_valid_json() -> None:
    def status_once(_: int) -> dict:
        process, payload = _run("status")
        assert process.returncode == 0
        return payload

    with ThreadPoolExecutor(max_workers=16) as pool:
        payloads = list(pool.map(status_once, range(100)))
    assert len(payloads) == 100
    assert all(payload["ok"] is True for payload in payloads)


def test_invalid_native_screen_precondition_fails_closed() -> None:
    process, payload = _run(
        "tap",
        "--x",
        "0.5",
        "--y",
        "0.5",
        "--expected-sha256",
        "not-a-hash",
    )
    assert process.returncode == 1
    assert payload["ok"] is False
    assert "64 hexadecimal" in payload["error"]
