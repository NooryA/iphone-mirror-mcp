# Security

## Scope

iPhone Mirror MCP intentionally controls only the visible `com.apple.ScreenContinuity` phone window. It exposes no arbitrary shell, filesystem, network, credential, or whole-desktop tool.

The helper validates the selected window and every pointer coordinate, serializes global input, rejects stale screenshot preconditions, and stops on recognized iPhone Mirroring host blocking states. macOS still treats Accessibility and Screen Recording as powerful permissions; grant them only to MCP clients you trust.

## Reporting a vulnerability

Please do not publish an exploit before a fix is available. Open a private GitHub security advisory for `NooryA/iphone-mirror-mcp` with:

- affected version and macOS version
- reproduction steps
- expected and observed behavior
- whether input escaped the iPhone Mirroring window or exposed unintended screen content

Do not include real credentials, private screenshots, or personal device data in a public issue.
