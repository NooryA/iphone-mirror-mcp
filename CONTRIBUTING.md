# Contributing

Contributions are welcome. Keep the controller narrowly scoped to the iPhone Mirroring window and preserve the no-arbitrary-shell boundary.

## Development checks

```bash
uv sync --all-groups
uv run ruff check .
uv run ruff format --check .
./scripts/build-native.sh
./dist/mirror-ctl self-test
uv run pytest -q --cov=iphone_mirror_mcp --cov-report=term-missing --cov-fail-under=80
uv build
./scripts/smoke-wheel.sh
```

Pull requests that change input or capture behavior should include regression coverage and note which of these were verified:

- main and secondary displays
- Retina scale changes
- a hidden/off-Space mirror window
- disconnected, setup, and iPhone-in-use states
- user pointer movement during HID input
- concurrent helper processes
- live physical-device tap, scroll, typing, and menu commands

Never add recordings, screenshots, credentials, device identifiers, or generated build output to the repository.
