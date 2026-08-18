# iPhone Mirror MCP

[![CI](https://github.com/NooryA/iphone-mirror-mcp/actions/workflows/ci.yml/badge.svg)](https://github.com/NooryA/iphone-mirror-mcp/actions/workflows/ci.yml)

A [Model Context Protocol](https://modelcontextprotocol.io) server that lets an AI agent drive a **physical iPhone** through the macOS **iPhone Mirroring** window.

Use it when you need the real device: StoreKit, system sheets, paywalls, push dialogs, or anything the iOS Simulator cannot reproduce. It is **not** whole-Mac computer use — it can only see and click that one window (`com.apple.ScreenContinuity`). There is no shell tool.

## How it works

iPhone Mirroring shows a live video of the phone. The iOS UI is **not** in the Mac Accessibility tree, so the server cannot receive named controls from Accessibility; it uses local OCR when targeting visible labels. It:

1. Screenshots the mirror window (Mac title bar cropped)
2. Maps taps in **normalized 0–1 coordinates** on that screenshot (origin: top-left of the phone screen)
3. Forwards those gestures into the mirroring window

Taps default to `skylight`: the backwards-compatible mode name for an orange overlay plus a short [cliclick](https://github.com/BlueM/cliclick) move/click/restore sequence. `hid` uses the same proven pointer backend without the overlay. Pure synthetic events can report success without becoming an iOS touch, so supported taps, scrolling, and typing fail closed when `cliclick` is unavailable. There is no iOS accessibility tree. Home / App Switcher / Spotlight go through iPhone Mirroring’s **View** menu. List scrolling uses a HID **scroll-wheel**.

```
Codex / Cursor / Claude  ──stdio──►  Python MCP  ──►  mirror-ctl (Swift)
                                                ├─ ScreenCaptureKit screenshot
                                                ├─ cliclick pointer input + overlay
                                                └─ Accessibility View menu
```

## Prerequisites

- macOS with [iPhone Mirroring](https://support.apple.com/guide/iphone/use-iphone-mirroring-iph373c7c223/ios) (Sequoia or later)
- An iPhone signed in to the same Apple ID, nearby, powered on, and locked after setup
- [Xcode Command Line Tools](https://developer.apple.com/xcode/resources/) (`swiftc`)
- [uv](https://docs.astral.sh/uv/) (Python 3.12+)
- [cliclick](https://github.com/BlueM/cliclick) — `brew install cliclick` (required for reliable taps, scrolling, and typing)

## Installation

```bash
git clone https://github.com/NooryA/iphone-mirror-mcp.git
cd iphone-mirror-mcp
uv sync
./scripts/build-native.sh
./dist/mirror-ctl doctor
```

`scripts/run.sh` rebuilds the Swift helper when native sources change, then starts the MCP server over stdio.

### Install from a built wheel

The wheel contains portable Swift source instead of an architecture-specific executable. On its first tool
call, the installed package compiles and ad-hoc-signs `mirror-ctl` into the user cache for the current macOS
architecture. Xcode Command Line Tools are therefore still required.

```bash
uv build
uv tool install dist/iphone_mirror_mcp-0.2.0-py3-none-any.whl
iphone-mirror-mcp
```

## Connect an MCP client

Replace `/absolute/path/to/iphone-mirror-mcp` with the clone path on your Mac.

### Codex and ChatGPT desktop

Codex CLI, the Codex IDE extension, and ChatGPT desktop share local MCP configuration. Add this STDIO server from the command line:

```bash
codex mcp add iphone-mirror -- /absolute/path/to/iphone-mirror-mcp/scripts/run.sh
codex mcp list
```

In ChatGPT desktop or the Codex IDE extension, you can instead open **Settings → MCP servers → Add server**, choose **STDIO**, and provide the absolute `scripts/run.sh` path. Restart the client after changing native or Python code. See the [official MCP configuration guide](https://developers.openai.com/codex/mcp).

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

1. **Accessibility** — taps, scrolling, typing, View menu
2. **Screen Recording** — screenshots of the mirror window

Keep iPhone Mirroring connected while the agent runs. Quitting the mirroring window **locks the phone**.

## Tools

Coordinates are **0–1**, origin **top-left** of the phone content in `mirror_screenshot` (the Mac title bar is already cropped; the **iOS status bar is in the image**). Do not flip Y. Nav / account icons are usually around **y = 0.04–0.08**, not 0.12.

Prefer `tap_label`, `find_text`, `scroll`, `tap_and_see`, `wait_for_change`, `find_bright`, and `find_color` over sleeping or guessing coordinates. If a result has `interactionBlocked: true`, resolve its `blockedReason` before continuing. For `iphone_in_use`, lock the phone to reconnect.

### `mirror_status`

Whether iPhone Mirroring is running, whether its phone window is visible on the current macOS Space, content/window bounds, selected display and scale, and permission status. A hidden or off-Space window is reported as `windowVisible: false` instead of failing the tool. The legacy `connected` field is explicitly accompanied by `connectionEvidence: "window-geometry-only"`; use screenshot host-state fields to confirm whether interaction is actually available.

### `mirror_doctor`

Read-only installation diagnostics: macOS and CPU architecture, displays, Accessibility and Screen Recording permissions, title-bar calibration source, `cliclick`, and actionable warnings.

```bash
./dist/mirror-ctl doctor
```

### `mirror_screenshot`

PNG of the phone screen. `width` / `height` are points; `pngWidth` / `pngHeight` are pixels. `iphoneInUse` is true only when local OCR confirms the “Lock your iPhone to connect” chrome; `iphoneInUseHeuristic` preserves the low-variance visual signal for diagnostics without blocking ordinary dark screens.

### `tap`

Tap the phone screen. Prefer `tap_and_see` when you need to confirm the UI changed.

```ts
{
  x: number; // 0–1
  y: number; // 0–1
  mode?: "hid" | "background" | "skylight"; // default "skylight"
  expected_sha256?: string; // optional stale-screen precondition
}
```

Default `skylight` is the backwards-compatible mode name for an overlay plus the proven `cliclick` backend. `hid` uses `cliclick` without the overlay. Both restore the Mac pointer unless real user movement is detected. `background` is retained for API compatibility but fails closed because `CGEvent.postToPid` does not deliver input to iOS.

Screenshots include both a difference-based `visualHash` and a versioned absolute-color `visualSignature`. Change detection combines them so tiny live-video noise is ignored without treating black, white, or equal-luminance color screens as identical. `tap_label` keeps its OCR source frame alive and the native helper compares it with a fresh frame while holding the cross-process input lock. For byte-for-byte state-sensitive actions, pass the `sha256` from the screenshot used to choose the target.

### `tap_and_see`

Tap, wait `settle_ms` (default 300), then screenshot. The native helper keeps one cross-process input lock across preflight, fresh normalized-coordinate mapping, the tap, settlement, and result capture.

### `wait_for_change`

Poll screenshots until either the structural `visualHash` or absolute-color `visualSignature` changes materially, or `timeout_ms` (default 8000) expires. Exact PNG changes are also reported as `sha256Changed`, but harmless live-video noise does not end the wait. Use after a tap that should open a sheet instead of a blind sleep.

### `find_color` / `find_bright`

Screenshot and return the **0–1 centroid** of matching pixels. Pass a tight region (`x0,y0,x1,y1`) — full-screen `find_bright` will hit titles, not icons.

```ts
// orange CTA
{ r: 255, g: 107, b: 53, tolerance?: 40, x0?: 0, y0?: 0.8, x1?: 1, y1?: 1 }

// white account icon, top-right
{ min_lum?: 200, x0: 0.75, y0: 0.02, x1: 0.98, y1: 0.10 }
```

Returns `{ found, n, cx, cy, bbox }` (`cx`/`cy` are null when `found` is false).

### `find_text`

Screenshot + on-device Vision OCR. Returns the 0–1 centroid of the best match. Use this instead of sending the PNG to a vision model.

```ts
{ query: "Face ID & Passcode", x0?: 0, y0?: 0, x1?: 1, y1?: 1, limit?: 8 }
```

### `tap_label`

`find_text` then tap the match and screenshot. One round-trip to click a visible row or button.

### `scroll`

HID scroll-wheel over the window. Negative `delta` shows items below. Use this for list movement; `swipe` is retained only as a fail-closed compatibility endpoint.

```ts
{ delta?: -12, ticks?: 8, x?: 0.5, y?: 0.55 }
```

### `swipe`

Swipe from `(x1, y1)` to `(x2, y2)` in 0–1 phone-content coordinates. Prefer `scroll` for Settings / history lists.

```ts
{
  x1: number;
  y1: number;
  x2: number;
  y2: number;
  duration_ms?: number; // default 180
  mode?: "hid" | "background" | "skylight";
}
```

This compatibility tool now fails closed with an actionable error: macOS reports drag events, but iPhone Mirroring does not deliver them to iOS. Use `scroll` for list movement instead of trusting a false success.

### `type_text`

Type a single line into the focused iOS field. Newlines are rejected because synthetic Return events do not reach iOS reliably.

### `press_key` / `press_return`

Compatibility endpoints that fail closed with an actionable error. Live testing confirmed that iPhone Mirroring ignores synthetic named-key events even though macOS reports them as posted.

### `open_app`

Opens an installed app via Spotlight. It confirms Spotlight before typing, excludes the query field from OCR result selection, clicks an exact result, and confirms a transition away from Spotlight before reporting success. The current confirmation markers recognize the English **Search**, **Siri Suggestions**, and **Show Less** labels; other macOS/iOS UI languages fail closed. Prefer this over tapping a Home Screen icon.

### `press_home` / `press_app_switcher` / `press_spotlight`

iPhone Mirroring → View menu. `press_home` leaves the current app.

## Usage

Typical loop for an agent:

1. `mirror_status` — window is up and Accessibility is trusted
2. `mirror_screenshot` — if `interactionBlocked`, resolve `blockedReason` and stop
3. `open_app("Safari")` (or your app name) instead of tapping Home icons
4. `find_text` / `tap_label("See monthly plan")` for visible words; `find_bright` / `find_color` only for icons
5. `scroll` to move Settings / history lists — do not swipe
6. `wait_for_change` when a sheet or navigation should appear — do not sleep 3–5s
7. If the UI did not change, retry the tap once at the same coords, then try a measured region

Do not call `press_home` unless you intend to leave the app.

## Configuration

Optional environment variables on the MCP server entry:

| Variable | Default | Description |
|---|---|---|
| `MIRROR_TITLEBAR_PT` | `52` | Mac title-bar height in points. Raise or lower if taps land too high or too low. |
| `MIRROR_HID_RESTORE` | (on) | Set to `0` to leave the Mac cursor at the input target (debug). |
| `MIRROR_CLICLICK_PATH` | auto | Absolute path to `cliclick`. Auto-detects Apple Silicon Homebrew, Intel Homebrew, and `PATH`. |
| `MIRROR_CTL_PATH` | auto | Explicit native-helper path. Normally unnecessary. |
| `MIRROR_NATIVE_CACHE_DIR` | user cache | Override where an installed wheel builds its architecture-specific helper. |

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
./dist/mirror-ctl doctor
./dist/mirror-ctl self-test
uv run ruff check .
uv run ruff format --check .
uv run pytest --cov=iphone_mirror_mcp
uv build
./scripts/smoke-wheel.sh
uv run iphone-mirror-mcp
```

The Swift helper lives in `native/Sources/` and compiles to `dist/mirror-ctl`. The Python MCP package is `src/iphone_mirror_mcp/`.

## Safety

- Clicks outside the mirroring window are refused
- Out-of-range and non-finite normalized coordinates are rejected, not clamped into an accidental edge click
- Global input is serialized across helper processes and MCP clients
- Host-state validation, fresh normalized-coordinate mapping, and supported input run in one native lock transaction
- Optional screenshot SHA-256 preconditions block stale-screen actions
- Absolute-color signatures plus structural hashes protect OCR label taps without missing flat/color-only transitions
- Known host blocking screens such as **iPhone in Use**, **iCloud Signed Out**, and setup/unavailable states are detected before input
- Pointer restoration does not overwrite user movement detected during a pointer action
- No arbitrary shell
- No telemetry
- HID mode moves the Mac cursor briefly

## Limitations

- Apple does not expose the mirrored iOS accessibility tree. OCR and visual targeting are best-effort.
- `MIRROR_TITLEBAR_PT` defaults to 52 points because macOS does not publish the remote app's `NSWindow.contentLayoutRect`. Use `mirror_doctor` and calibrate only when screenshots or taps visibly disagree.
- The `skylight` mode name is retained for backward compatibility, but reliable input uses `cliclick`; unsupported synthetic paths fail closed instead of claiming success.
- A physical device must be signed in and available to iPhone Mirroring. Automated CI builds and stress-tests the controller but cannot perform a live-device gesture.
- Spotlight UI confirmation currently recognizes English Search/Siri Suggestions/Show Less labels and fails closed for unrecognized localization.
- This is intentionally a one-window controller. It does not provide general Mac automation or remote network access.

## License

[MIT](LICENSE)
