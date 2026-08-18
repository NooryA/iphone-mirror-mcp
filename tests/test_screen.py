from pathlib import Path

import pytest
from PIL import Image

from iphone_mirror_mcp.screen import (
    blocked_reason_from_ocr,
    detect_iphone_in_use,
    find_pixels,
    sha256_file,
    visual_hash_distance,
    visual_hash_file,
    visual_signature_distance,
    visual_signature_file,
)


def _write(path: Path, pixels: list[tuple[int, int, int]], size: tuple[int, int] = (64, 128)) -> None:
    image = Image.new("RGB", size)
    image.putdata(pixels)
    image.save(path)


def test_detects_flat_gray_iphone_in_use_chrome(tmp_path: Path) -> None:
    path = tmp_path / "in-use.png"
    pixels = [(42, 42, 44)] * (64 * 128)
    # small blue glyph in the center, like the iPhone icon
    for y in range(40, 52):
        for x in range(28, 36):
            pixels[y * 64 + x] = (90, 160, 220)
    _write(path, pixels)
    assert detect_iphone_in_use(str(path)) is True


def test_busy_app_ui_is_not_iphone_in_use(tmp_path: Path) -> None:
    path = tmp_path / "app.png"
    pixels = []
    for y in range(128):
        for x in range(64):
            if y < 12:
                pixels.append((0, 0, 0))
            elif 12 <= y <= 20 and x > 50:
                pixels.append((250, 250, 250))
            elif y > 110 and x > 48:
                pixels.append((255, 107, 53))
            else:
                pixels.append((0, 0, 0) if (x + y) % 7 else (30, 30, 30))
    _write(path, pixels)
    assert detect_iphone_in_use(str(path)) is False


def test_find_bright_centroid(tmp_path: Path) -> None:
    path = tmp_path / "icon.png"
    image = Image.new("RGB", (100, 100), (0, 0, 0))
    for y in range(8, 16):
        for x in range(80, 90):
            image.putpixel((x, y), (255, 255, 255))
    image.save(path)
    hit = find_pixels(str(path), min_lum=200, x0=0.7, y0=0.0, x1=1.0, y1=0.25, min_pixels=10)
    assert hit["found"] is True
    assert 0.82 < hit["cx"] < 0.88
    assert 0.08 < hit["cy"] < 0.16


def test_find_color_miss_returns_found_false(tmp_path: Path) -> None:
    path = tmp_path / "empty.png"
    Image.new("RGB", (40, 40), (0, 0, 0)).save(path)
    miss = find_pixels(str(path), red=255, green=0, blue=0, tolerance=10, min_pixels=5)
    assert miss["found"] is False
    assert miss["n"] == 0


def test_sha256_changes_when_pixels_change(tmp_path: Path) -> None:
    a = tmp_path / "a.png"
    b = tmp_path / "b.png"
    Image.new("RGB", (8, 8), (0, 0, 0)).save(a)
    Image.new("RGB", (8, 8), (1, 0, 0)).save(b)
    assert sha256_file(str(a)) != sha256_file(str(b))


def test_visual_hash_ignores_tiny_noise_but_detects_screen_change(tmp_path: Path) -> None:
    increasing = Image.new("L", (90, 80))
    increasing.putdata([int(x * 255 / 89) for _y in range(80) for x in range(90)])
    noisy = increasing.copy()
    noisy.putpixel((4, 4), min(255, noisy.getpixel((4, 4)) + 1))
    decreasing = Image.new("L", (90, 80))
    decreasing.putdata([255 - int(x * 255 / 89) for _y in range(80) for x in range(90)])

    paths = [tmp_path / name for name in ("increasing.png", "noisy.png", "decreasing.png")]
    for image, path in zip((increasing, noisy, decreasing), paths, strict=True):
        image.save(path)

    base_hash = visual_hash_file(str(paths[0]))
    noisy_hash = visual_hash_file(str(paths[1]))
    changed_hash = visual_hash_file(str(paths[2]))
    assert base_hash == noisy_hash
    assert visual_hash_distance(base_hash, changed_hash) == 64


def test_visual_signature_detects_flat_color_and_content_transitions(tmp_path: Path) -> None:
    black = tmp_path / "black.png"
    white = tmp_path / "white.png"
    red = tmp_path / "red.png"
    blue = tmp_path / "blue.png"
    before = tmp_path / "before.png"
    after = tmp_path / "after.png"
    Image.new("RGB", (160, 320), "black").save(black)
    Image.new("RGB", (160, 320), "white").save(white)
    Image.new("RGB", (160, 320), "red").save(red)
    Image.new("RGB", (160, 320), "blue").save(blue)
    before_image = Image.new("RGB", (160, 320), "black")
    after_image = before_image.copy()
    for y in range(80, 240):
        for x in range(10, 70):
            before_image.putpixel((x, y), (255, 255, 255))
        for x in range(90, 150):
            after_image.putpixel((x, y), (255, 255, 255))
    before_image.save(before)
    after_image.save(after)

    assert (
        visual_signature_distance(visual_signature_file(str(black)), visual_signature_file(str(white))) == 255
    )
    assert visual_signature_distance(visual_signature_file(str(red)), visual_signature_file(str(blue))) > 100
    assert (
        visual_signature_distance(visual_signature_file(str(before)), visual_signature_file(str(after))) > 20
    )


def test_visual_signature_ignores_single_pixel_noise(tmp_path: Path) -> None:
    baseline = tmp_path / "baseline.png"
    noisy = tmp_path / "noisy.png"
    image = Image.new("RGB", (160, 320), (80, 120, 160))
    image.save(baseline)
    image.putpixel((1, 1), (81, 120, 160))
    image.save(noisy)
    assert (
        visual_signature_distance(visual_signature_file(str(baseline)), visual_signature_file(str(noisy)))
        == 0
    )


@pytest.mark.parametrize("invalid", ["", "rgb16:zz", "rgb8:00", "rgb16:00"])
def test_visual_signature_rejects_invalid_format(tmp_path: Path, invalid: str) -> None:
    valid_path = tmp_path / "valid.png"
    Image.new("RGB", (32, 32), "black").save(valid_path)
    with pytest.raises(ValueError, match="visual signature"):
        visual_signature_distance(visual_signature_file(str(valid_path)), invalid)


def test_visual_iphone_in_use_heuristic_alone_does_not_block() -> None:
    assert blocked_reason_from_ocr([], iphone_in_use=True) is None


def test_ocr_confirms_iphone_in_use() -> None:
    assert (
        blocked_reason_from_ocr([{"text": "Lock your iPhone to connect"}], iphone_in_use=True)
        == "iphone_in_use"
    )


def test_blocked_reason_combines_ocr_lines() -> None:
    matches = [{"text": "iCloud Signed Out"}, {"text": "Sign in to iCloud to continue."}]
    assert blocked_reason_from_ocr(matches, iphone_in_use=False) == "icloud_signed_out"


def test_connection_paused_is_a_host_blocker() -> None:
    assert (
        blocked_reason_from_ocr([{"text": "Connection Paused"}, {"text": "Resume"}], iphone_in_use=False)
        == "connection_paused"
    )


def test_ordinary_iphone_ui_is_not_a_host_blocker() -> None:
    matches = [{"text": "Settings"}, {"text": "Sign in to your iPhone"}]
    assert blocked_reason_from_ocr(matches, iphone_in_use=False) is None
