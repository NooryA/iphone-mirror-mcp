import asyncio
import base64
import json
import os
import sys
from pathlib import Path

from mcp import ClientSession, StdioServerParameters
from mcp.client.stdio import stdio_client

ROOT = Path(__file__).resolve().parents[1]


def test_real_stdio_server_initializes_lists_tools_and_runs_doctor() -> None:
    async def exercise() -> None:
        parameters = StdioServerParameters(command=str(ROOT / "scripts" / "run.sh"))
        async with (
            stdio_client(parameters) as (read_stream, write_stream),
            ClientSession(read_stream, write_stream) as session,
        ):
            initialized = await session.initialize()
            assert initialized.server_info.name == "iphone-mirror"
            assert "Coordinates are 0-1" in (initialized.instructions or "")

            tools = await session.list_tools()
            names = {tool.name for tool in tools.tools}
            assert {"mirror_status", "mirror_doctor", "mirror_screenshot", "tap", "tap_label"} <= names

            doctor = await session.call_tool("mirror_doctor", {})
            assert doctor.is_error is False
            assert doctor.structured_content is not None
            assert doctor.structured_content["ok"] is True
            status = doctor.structured_content.get("status") or {}
            if status.get("windowVisible") and status.get("screenCaptureAllowed"):
                screenshot = await session.call_tool("mirror_screenshot", {})
                assert screenshot.is_error is False
                assert screenshot.structured_content["pngWidth"] > 0
                images = [block for block in screenshot.content if block.type == "image"]
                assert len(images) == 1
                assert base64.b64decode(images[0].data).startswith(b"\x89PNG")

    asyncio.run(asyncio.wait_for(exercise(), timeout=30))


def _fake_native(tmp_path: Path) -> Path:
    script = tmp_path / "fake-mirror-ctl"
    script.write_text(
        f"""#!{sys.executable}
import json
import sys
from PIL import Image

args = sys.argv[1:]
command = args[0]
def value(flag):
    return args[args.index(flag) + 1]

if command in {{"screenshot", "capture-analyze", "tap-and-capture", "tap-label-and-capture"}}:
    output = value("--out")
    Image.new("RGB", (32, 64), (20, 40, 60)).save(output)
    result = {{
        "ok": True,
        "path": output,
        "windowId": 7,
        "width": 16,
        "height": 32,
        "contentX": 100,
        "contentY": 200,
        "contentWidth": 16,
        "contentHeight": 32,
    }}
    if command == "capture-analyze":
        result.update({{
            "iphoneInUse": False,
            "interactionBlocked": False,
            "blockedReason": None,
        }})
        if "--query" in args:
            query = value("--query")
            matches = []
            if query == "Settings":
                matches = [{{"text": "Settings", "cx": 0.4, "cy": 0.3, "confidence": 0.99}}]
            result["ocr"] = {{"ok": True, "found": bool(matches), "query": query, "matches": matches}}
            if matches:
                result["ocr"].update(matches[0])
    if command == "tap-and-capture":
        settle = int(value("--settle-ms"))
        result["tap"] = {{"ok": True}}
        result["preflightSha256"] = "a" * 64
        result["screenChanged"] = True
        result["visualDistanceFromPreflight"] = 12.0
        result.update({{
            "settleMs": settle,
            "maximumSettleMs": settle,
            "settledMs": min(settle, 180),
            "settlementCaptures": 2,
            "screenStable": True,
            "settlementTimedOut": False,
            "settlementState": "settled",
        }})
        result.update({{"iphoneInUse": False, "interactionBlocked": False, "blockedReason": None}})
    if command == "tap-label-and-capture":
        query = value("--query")
        found = query == "Settings"
        result["atomicLabelSelection"] = True
        result["tap"] = {{"ok": found}}
        result["screenChanged"] = found
        result["visualDistanceFromPreflight"] = 12.0 if found else 0.0
        if found:
            settle = int(value("--settle-ms"))
            result.update({{
                "settleMs": settle,
                "maximumSettleMs": settle,
                "settledMs": min(settle, 180),
                "settlementCaptures": 2,
                "screenStable": True,
                "settlementTimedOut": False,
                "settlementState": "settled",
            }})
        result["ocr"] = {{"query": query, "found": found, "matches": []}}
        result.update({{"iphoneInUse": False, "interactionBlocked": False, "blockedReason": None}})
elif command == "ocr":
    query = value("--query")
    matches = []
    if query == "Settings":
        matches = [{{"text": "Settings", "cx": 0.4, "cy": 0.3, "confidence": 0.99}}]
    result = {{"ok": True, "found": bool(matches), "query": query, "matches": matches}}
    if matches:
        result.update(matches[0])
elif command == "doctor":
    result = {{"ok": True, "healthy": True}}
elif command == "status":
    result = {{"ok": True, "running": True, "windowVisible": True}}
else:
    result = {{"ok": True, "command": command, "preflightSha256": "a" * 64}}
    if command == "type":
        result["receivedText"] = value("--text")
    if command == "open-app":
        result["receivedName"] = value("--name")
print(json.dumps(result))
"""
    )
    script.chmod(0o700)
    return script


def test_all_image_tool_families_serialize_over_real_stdio(
    tmp_path: Path,
) -> None:
    fake = _fake_native(tmp_path)

    async def exercise() -> None:
        env = os.environ.copy()
        env["MIRROR_CTL_PATH"] = str(fake)
        parameters = StdioServerParameters(
            command=sys.executable,
            args=["-m", "iphone_mirror_mcp"],
            env=env,
        )
        async with (
            stdio_client(parameters) as (read_stream, write_stream),
            ClientSession(read_stream, write_stream) as session,
        ):
            await session.initialize()
            calls = (
                ("mirror_screenshot", {}, None),
                ("wait_for_change", {"timeout_ms": 0}, None),
                ("tap_label", {"query": "Missing", "settle_ms": 0}, None),
                ("tap_label", {"query": "Settings", "settle_ms": 0}, 0),
                ("tap_label", {"query": "Settings"}, 1_500),
                ("tap_and_see", {"x": 0.5, "y": 0.5, "settle_ms": 0}, 0),
                ("tap_and_see", {"x": 0.5, "y": 0.5}, 1_500),
            )
            for name, arguments, expected_settle in calls:
                result = await session.call_tool(name, arguments)
                assert result.is_error is False, (name, result)
                assert result.structured_content is not None
                text_blocks = [block for block in result.content if block.type == "text"]
                image_blocks = [block for block in result.content if block.type == "image"]
                assert len(text_blocks) == 1
                assert len(image_blocks) == 1
                assert json.loads(text_blocks[0].text) == result.structured_content
                assert image_blocks[0].mime_type == "image/png"
                assert base64.b64decode(image_blocks[0].data).startswith(b"\x89PNG")
                if expected_settle is not None:
                    assert result.structured_content["settleMs"] == expected_settle
                    assert result.structured_content["maximumSettleMs"] == expected_settle
                    assert result.structured_content["screenStable"] is True

            found = await session.call_tool("find_text", {"query": "--foo"})
            assert found.is_error is False
            assert found.structured_content["query"] == "--foo"
            typed = await session.call_tool("type_text", {"text": "--foo"})
            assert typed.is_error is False
            assert typed.structured_content["receivedText"] == "--foo"
            opened = await session.call_tool("open_app", {"name": "--foo"})
            assert opened.is_error is False
            assert opened.structured_content["receivedName"] == "--foo"

    asyncio.run(asyncio.wait_for(exercise(), timeout=30))
