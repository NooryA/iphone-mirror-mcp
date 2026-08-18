# Security

## Scope

iPhone Mirror MCP intentionally controls only the visible `com.apple.ScreenContinuity` phone window. It exposes no arbitrary shell, filesystem, network, credential, or whole-desktop tool.

The helper validates the selected window and every pointer coordinate, captures only that window ID, and serializes global input. Under that lock it activates and resolves the mirror before capturing/preflighting the exact window, then verifies the same identity immediately before input. Activation is confirmed from the real frontmost process; native activation gets a short grace period before a bounded AppleScript fallback containing only the fixed `com.apple.ScreenContinuity` bundle ID, never caller-controlled script. Label OCR and target selection occur inside that transaction. Global input requires iPhone Mirroring to be frontmost; taps use explicit coordinates, scrolling aborts when focus or pointer ownership changes, and long typing rechecks between bounded chunks. Timed-out helpers and their children are terminated as one process group. Exact or visual preconditions reject stale targets. macOS still treats Accessibility and Screen Recording as powerful permissions; grant them only to MCP clients you trust.

## Reporting a vulnerability

Please do not publish an exploit before a fix is available. Open a private GitHub security advisory for `NooryA/iphone-mirror-mcp` with:

- affected version and macOS version
- reproduction steps
- expected and observed behavior
- whether input escaped the iPhone Mirroring window or exposed unintended screen content

Do not include real credentials, private screenshots, or personal device data in a public issue.
