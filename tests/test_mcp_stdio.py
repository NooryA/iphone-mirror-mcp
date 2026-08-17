import asyncio
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

    asyncio.run(asyncio.wait_for(exercise(), timeout=30))
