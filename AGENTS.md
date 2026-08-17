# Agent notes

This server drives a **physical iPhone** through the macOS iPhone Mirroring window. There is no accessibility tree for iOS UI.

## Loop

1. `mirror_doctor` when setup is uncertain, then `mirror_status` and `mirror_screenshot`. Stop if `iphoneInUse` or `interactionBlocked`.
2. `open_app("Name")` — not Home icons, not `press_home`.
3. `find_text` / `tap_label` for visible words, `find_bright` / `find_color` in a tight region for icons, then `tap_and_see`.
4. `scroll` to move lists. `wait_for_change` when a sheet or new screen should appear. Do not sleep.
5. Pass the observed screenshot `sha256` as `expected_sha256` for state-sensitive actions.
6. After each screenshot, inspect the **whole** screen for bugs (missing images, blank cards, LogBox) — not only the tap target. A pass-through screen still counts.

Coords are 0–1, top-left of the screenshot. The iOS status bar is in the image; nav icons are about y=0.04–0.08. Never flip Y. Default tap mode is `skylight` (cliclick + orange overlay); `hid` uses cliclick without the overlay. Pure SkyLight/postToPid does not reach iOS.

## Do not

Use Maestro, WebDriverAgent, or XCTest against the same phone while mirroring. Reload this MCP after pulling native or Python changes.
