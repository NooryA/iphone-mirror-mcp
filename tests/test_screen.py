from pathlib import Path

from PIL import Image

from iphone_mirror_mcp.screen import detect_iphone_in_use, find_pixels, sha256_file


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
