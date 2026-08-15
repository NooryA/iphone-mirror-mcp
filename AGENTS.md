# Agent notes

This server drives a **physical iPhone** through the macOS iPhone Mirroring window. There is no accessibility tree for iOS UI.

## Loop

1. `mirror_status` then `mirror_screenshot`. Stop if `iphoneInUse`.
2. `open_app("Name")` — not Home icons, not `press_home`.
3. `find_bright` / `find_color` in a tight region, then `tap_and_see`.
4. `wait_for_change` when a sheet or new screen should appear. Do not sleep.

Coords are 0–1, top-left of the screenshot. The iOS status bar is in the image; nav icons are about y=0.04–0.08. Never flip Y.

## Do not

Use Maestro, WebDriverAgent, or XCTest against the same phone while mirroring. Reload this MCP after pulling native or Python changes.
