# iPhone Mirror MCP

A [Model Context Protocol](https://modelcontextprotocol.io) server that lets an AI agent drive a **physical iPhone** through the macOS **iPhone Mirroring** window.

Use it when you need the real device: StoreKit, system sheets, paywalls, push dialogs, or anything the iOS Simulator cannot reproduce. It is **not** whole-Mac computer use — it can only see and click that one window (`com.apple.ScreenContinuity`). There is no shell tool.

## How it works

iPhone Mirroring shows a live video of the phone. The iOS UI is **not** in the Mac Accessibility tree, so this server does not click named buttons. It:

1. Screenshots the mirror window (Mac title bar cropped)
2. Maps taps and swipes in **normalized 0–1 coordinates** on that screenshot (origin: top-left of the phone screen)
3. Forwards those gestures into the mirroring window

Taps use [cliclick](https://github.com/BlueM/cliclick) when it is installed (`hid` mode). That briefly moves the Mac cursor onto the window, then restores it. Keyboard input is HID key events. Home / App Switcher / Spotlight go through iPhone Mirroring’s **View** menu.

```
Cursor / Claude  ──stdio──►  Python MCP  ──►  dist/mirror-ctl (Swift)
                                                ├─ ScreenCaptureKit screenshot
                                                ├─ cliclick / HID tap & swipe
                                                └─ Accessibility View menu
```

## Prerequisites

- macOS with [iPhone Mirroring](https://support.apple.com/guide/iphone/use-iphone-mirroring-iph373c7c223/ios) (Sequoia or later)
- An iPhone signed in to the same Apple ID, unlocked, and connected in the iPhone Mirroring app
- [Xcode Command Line Tools](https://developer.apple.com/xcode/resources/) (`swiftc`)
- [uv](https://docs.astral.sh/uv/) (Python 3.12+)
- [cliclick](https://github.com/BlueM/cliclick) — `brew install cliclick` (recommended for taps)

## Installation

```bash
git clone https://github.com/NooryA/iphone-mirror-mcp.git
cd iphone-mirror-mcp
uv sync
./scripts/build-native.sh
```

`scripts/run.sh` rebuilds the Swift helper when native sources change, then starts the MCP server over stdio.

## Connect an MCP client

Replace `/absolute/path/to/iphone-mirror-mcp` with the clone path on your Mac.

### Cursor

Cursor reads MCP servers from `~/.cursor/mcp.json` (all projects) or `.cursor/mcp.json` (this workspace).

```json
{
  "mcpServers": {
    "iphone-mirror": {
      "command": "/absolute/path/to/iphone-mirror-mcp/scripts/run.sh"
    }
  }
}
```

Reload MCP servers in Cursor Settings → MCP after saving. After you pull native or Python changes, reload **iphone-mirror** so the client is not stuck on an old tool catalog.

### Claude Code

```bash
claude mcp add iphone-mirror -- /absolute/path/to/iphone-mirror-mcp/scripts/run.sh
```

### Claude Desktop

Edit `~/Library/Application Support/Claude/claude_desktop_config.json`:

```json
{
  "mcpServers": {
    "iphone-mirror": {
      "command": "/absolute/path/to/iphone-mirror-mcp/scripts/run.sh"
    }
  }
}
```

Restart Claude Desktop.

## Permissions

Grant these to the **MCP client app** (Cursor, Claude, etc.) — not Terminal — in **System Settings → Privacy & Security**:

1. **Accessibility** — taps, swipes, typing, View menu
2. **Screen Recording** — screenshots of the mirror window

Keep iPhone Mirroring connected while the agent runs. Quitting the mirroring window **locks the phone**.

## Tools

Coordinates are **0–1**, origin **top-left** of the phone content in `mirror_screenshot` (the Mac title bar is already cropped). Do not flip Y.

### `mirror_status`

Whether iPhone Mirroring is running, window bounds, and Accessibility trust.

### `mirror_screenshot`

PNG of the phone screen. `width` / `height` match the image in points — use this frame for every tap.

### `tap`

Tap the phone screen.

```ts
{
  x: number; // 0–1
  y: number; // 0–1
  mode?: "hid" | "background"; // default "hid"
}
```

Use `hid` (default). `background` (`CGEvent.postToPid`) does not deliver mouse events to iPhone Mirroring.

### `swipe`

Swipe from `(x1, y1)` to `(x2, y2)` in 0–1 phone-content coordinates.

```ts
{
  x1: number;
  y1: number;
  x2: number;
  y2: number;
  duration_ms?: number; // default 180
  mode?: "hid" | "background";
}
```

Fast flicks work better than slow drags.

### `type_text`

Type into the focused iOS field. Prefer ASCII. A newline sends Return.

### `press_key` / `press_return`

Named keys: `return`, `escape`, `tab`, `delete`, `space`, `up`, `down`, `left`, `right`.

### `open_app`

Opens an installed app via Spotlight (View menu → type name → Return). Prefer this over tapping a Home Screen icon.

### `press_home` / `press_app_switcher` / `press_spotlight`

iPhone Mirroring → View menu. `press_home` leaves the current app.

## Usage

Typical loop for an agent:

1. `mirror_status` — window is up and Accessibility is trusted
2. `mirror_screenshot` — map taps from **this** image (0–1)
3. `open_app("Safari")` (or your app name) instead of tapping Home icons
4. `tap` / `swipe` / `type_text`, wait about a second, screenshot again
5. If the UI did not change, retry the tap once, then try `press_return` if a field is focused

Do not call `press_home` unless you intend to leave the app.

## Configuration

Optional environment variables on the MCP server entry:

| Variable | Default | Description |
|---|---|---|
| `MIRROR_TITLEBAR_PT` | `52` | Mac title-bar height in points. Raise or lower if taps land too high or too low. |
| `MIRROR_HID_RESTORE` | (on) | Set to `0` to leave the Mac cursor on the tap target (debug). |

Example:

```json
{
  "mcpServers": {
    "iphone-mirror": {
      "command": "/absolute/path/to/iphone-mirror-mcp/scripts/run.sh",
      "env": {
        "MIRROR_TITLEBAR_PT": "52"
      }
    }
  }
}
```

## Development

```bash
./scripts/build-native.sh
./dist/mirror-ctl status
uv run pytest
uv run iphone-mirror-mcp
```

The Swift helper lives in `native/Sources/` and compiles to `dist/mirror-ctl`. The Python MCP package is `src/iphone_mirror_mcp/`.

## Safety

- Clicks outside the mirroring window are refused
- No arbitrary shell
- No telemetry
- HID mode moves the Mac cursor briefly

## License

[MIT](LICENSE)
