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

Coordinates are **0–1**, origin **top-left** of the phone content in `mirror_screenshot` (the Mac title bar is already cropped; the **iOS status bar is in the image**). Do not flip Y. Nav / account icons are usually around **y = 0.04–0.08**, not 0.12.

Prefer `tap_and_see`, `wait_for_change`, `find_bright`, and `find_color` over sleeping or guessing coordinates. If a result has `iphoneInUse: true`, stop tapping — the phone must be locked to reconnect.

### `mirror_status`

Whether iPhone Mirroring is running, window bounds, and Accessibility trust.

### `mirror_screenshot`

PNG of the phone screen. `width` / `height` are points; `pngWidth` / `pngHeight` are pixels. `iphoneInUse` is true when the window is the “Lock your iPhone to connect” chrome.

### `tap`

Tap the phone screen. Prefer `tap_and_see` when you need to confirm the UI changed.

```ts
{
  x: number; // 0–1
  y: number; // 0–1
  mode?: "hid" | "background"; // default "hid"
}
```

Use `hid` (default). `background` (`CGEvent.postToPid`) does not deliver mouse events to iPhone Mirroring.

### `tap_and_see`

Tap, wait `settle_ms` (default 450), then screenshot. One round-trip instead of tap + sleep + screenshot.

### `wait_for_change`

Poll screenshots until the PNG hash changes or `timeout_ms` (default 8000). Use after a tap that should open a sheet, instead of a blind sleep.

### `find_color` / `find_bright`

Screenshot and return the **0–1 centroid** of matching pixels. Pass a tight region (`x0,y0,x1,y1`) — full-screen `find_bright` will hit titles, not icons.

```ts
// orange CTA
{ r: 255, g: 107, b: 53, tolerance?: 40, x0?: 0, y0?: 0.8, x1?: 1, y1?: 1 }

// white account icon, top-right
{ min_lum?: 200, x0: 0.75, y0: 0.02, x1: 0.98, y1: 0.10 }
```

Returns `{ found, n, cx, cy, bbox }` (`cx`/`cy` are null when `found` is false).

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
2. `mirror_screenshot` — if `iphoneInUse`, stop
3. `open_app("Safari")` (or your app name) instead of tapping Home icons
4. `find_bright` / `find_color` in a tight region, then `tap_and_see` at `cx, cy`
5. `wait_for_change` when a sheet or navigation should appear — do not sleep 3–5s
6. If the UI did not change, retry the tap once at the same coords, then try a measured region

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
