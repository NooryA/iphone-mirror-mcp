from __future__ import annotations

import asyncio
import sys
from importlib.metadata import version

from mcp import ClientSession, StdioServerParameters
from mcp.client.stdio import stdio_client

from iphone_mirror_mcp import __version__
from iphone_mirror_mcp.ctl import _native_binary, run_ctl


async def exercise_mcp() -> None:
    parameters = StdioServerParameters(command=sys.executable, args=["-m", "iphone_mirror_mcp"])
    async with stdio_client(parameters) as (reader, writer), ClientSession(reader, writer) as session:
        await session.initialize()
        tools = await session.list_tools()
        names = {tool.name for tool in tools.tools}
        assert {"mirror_doctor", "mirror_screenshot", "tap"} <= names
        doctor = await session.call_tool("mirror_doctor", {})
        assert doctor.is_error is False
        assert doctor.structured_content is not None
        assert doctor.structured_content["ok"] is True


def main() -> None:
    assert version("iphone-mirror-mcp") == __version__
    assert run_ctl("self-test")["ok"] is True
    binary = _native_binary()
    binary.write_bytes(b"corrupt cached helper")
    binary.chmod(0o700)
    assert run_ctl("self-test")["ok"] is True
    assert binary.read_bytes() != b"corrupt cached helper"
    assert binary.stat().st_size > 100_000
    assert run_ctl("doctor")["ok"] is True
    asyncio.run(asyncio.wait_for(exercise_mcp(), timeout=30))


if __name__ == "__main__":
    main()
