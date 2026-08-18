# Changelog

## 0.3.0

- Fuse capture, host-state classification, and optional text search into one native command instead of launching
  separate capture and OCR processes.
- Use fast Vision recognition for read-only analysis and retry accurate recognition only when a requested label is
  missed.
- Reuse accurate preflight OCR observations for atomic label targeting instead of OCRing the same frame twice.
- Adaptively capture after taps until a material transition has a stable follow-up frame or the caller's settlement
  budget is reached. Combine structural and absolute-color evidence, distinguish settled/time-out states, and
  preserve `settleMs` as a response-compatibility alias.
- Reduce each tap to one explicit absolute `cliclick` command while preserving coordinate, focus, and user-pointer
  guards.
- Verify the real frontmost process after activation, allow native activation a short grace period, and use a
  bounded, fixed-bundle AppleScript fallback only when native activation remains unconfirmed.
- Accurately recheck fast-OCR results that resemble known iPhone Mirroring host warnings before publishing the
  read-only interaction state, while preserving definitive blocker evidence found by either OCR pass.
- Decode captured images once when deriving Python-side hashes, dimensions, and host-state heuristics.
- On the live test Mac and physical iPhone, warm median MCP screenshot time fell from about 671 ms to 311 ms and a
  common `find_text` hit from about 1002 ms to 318 ms. Hardware, UI state, and first-run native compilation affect
  absolute timings.

## 0.2.0

- Select the actual phone window instead of larger setup or welcome windows.
- Map capture scale and overlays to the display containing iPhone Mirroring.
- Report running-but-hidden windows without failing `mirror_status`.
- Add `mirror_doctor` and native geometry/window-selection self-tests.
- Serialize global input across processes, including the full Spotlight/open-app sequence, and avoid
  overwriting detected user pointer movement.
- Add optional SHA-256 screen preconditions for state-sensitive actions.
- Under one native cross-process lock, activate and resolve the mirror before capturing/preflighting that exact
  window, then verify the same identity immediately before supported input.
- Run label capture, host validation, OCR target selection, tap, settlement, and result capture in one native
  transaction so pre-lock OCR coordinates are never trusted.
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
- Capture the resolved window ID in the `screencapture` fallback so overlapping desktop content cannot enter
  phone screenshots or OCR.
- Require verified frontmost activation before global input, click explicit absolute coordinates, and abort
  scrolling before the next tick when focus or pointer ownership changes.
- Bound native `cliclick` execution, chunk long typing with focus/window checks, derive the outer typing deadline,
  and kill/reap the entire native process group on timeout so input cannot outlive a failed MCP call.
- Preflight the `cliclick` dependency before activation or View-menu changes so `open_app` cannot leave Spotlight
  open when its typing backend is already known to be unavailable.
- Bundle native source in wheels and atomically compile a signed, integrity-checked, architecture-specific helper
  into the user cache on first use.
- Keep the Python package and distribution version synchronized.
- Remove the unused private SkyLight framework event path while retaining the `skylight` mode name for compatibility.
- Remove screenshot temporary files deterministically.
- Add macOS CI, lint/format enforcement, concurrency stress tests, and coverage enforcement.

## 0.1.0

- Initial public MCP server with ScreenCaptureKit capture, Vision OCR, normalized coordinates, ghost-HID taps, HID scrolling, typing, and iPhone Mirroring menu commands.
