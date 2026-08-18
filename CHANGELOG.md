# Changelog

## 0.2.0

- Select the actual phone window instead of larger setup or welcome windows.
- Map capture scale and overlays to the display containing iPhone Mirroring.
- Report running-but-hidden windows without failing `mirror_status`.
- Add `mirror_doctor` and native geometry/window-selection self-tests.
- Serialize global input across processes, including the full Spotlight/open-app sequence, and avoid
  overwriting detected user pointer movement.
- Add optional SHA-256 screen preconditions for state-sensitive actions.
- Execute host-state validation, fresh normalized mapping, and supported input under one native cross-process lock.
- Use structural hashes plus versioned absolute-color signatures so live-video noise is ignored without missing
  flat/color-only screen transitions.
- Detect known iPhone Mirroring host blocking screens before input, including live-observed Connection Paused.
- Reject invalid coordinates and bound durations, waits, scrolling, text, OCR, and search regions.
- Discover `cliclick` across Apple Silicon, Intel Homebrew, `PATH`, and explicit configuration.
- Route supported taps, scrolling, and typing through the live-verified `cliclick` backend and fail closed
  instead of reporting success for synthetic events that iPhone Mirroring ignores.
- Keep `swipe` for API compatibility but fail with an actionable `use scroll` error after live testing
  confirmed that iPhone Mirroring ignores pointer drag events.
- Keep named-key endpoints for API compatibility but fail closed after live tests confirmed that
  Return and Delete events are ignored; reject newline-as-Return in `type_text` for the same reason.
- Retain `background` mode in the schema for compatibility but fail closed instead of reporting
  success for `CGEvent.postToPid` events that iOS never receives.
- Require the verified pointer backend for scrolling instead of silently falling back to an
  unverified internal cursor warp.
- Make `open_app` confirm Spotlight before typing, exclude the query field, click an exact result, and confirm
  the transition away from Spotlight instead of assuming Return or a posted event worked.
- Remove the unverified menu keyboard-shortcut fallback; Accessibility menu failures now fail closed.
- Preserve arbitrary leading-dash and Unicode CLI values while rejecting unknown, duplicate, and missing flags.
- Return explicit MCP image content plus structured metadata and exercise every image-tool family over stdio.
- Isolate timed-out ScreenCaptureKit work from the fallback destination to prevent late-writer races.
- Bundle native source in wheels and compile a signed, architecture-specific helper into the user cache on first use.
- Keep the Python package and distribution version synchronized.
- Remove the unused private SkyLight framework event path while retaining the `skylight` mode name for compatibility.
- Remove screenshot temporary files deterministically.
- Add macOS CI, lint/format enforcement, concurrency stress tests, and coverage enforcement.

## 0.1.0

- Initial public MCP server with ScreenCaptureKit capture, Vision OCR, normalized coordinates, ghost-HID taps, HID scrolling, typing, and iPhone Mirroring menu commands.
