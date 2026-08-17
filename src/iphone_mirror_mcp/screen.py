from __future__ import annotations

import hashlib
from typing import Any

from PIL import Image

_BLOCKED_TEXT_MARKERS = (
    ("lock your iphone to connect", "iphone_in_use"),
    ("iphone in use", "iphone_in_use"),
    ("icloud signed out", "icloud_signed_out"),
    ("sign in to icloud to continue", "icloud_signed_out"),
    ("welcome to iphone mirroring", "setup_required"),
    ("iphone mirroring not available", "mirroring_unavailable"),
    ("unable to connect to iphone", "connection_unavailable"),
)


def sha256_file(path: str) -> str:
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for chunk in iter(lambda: handle.read(65536), b""):
            digest.update(chunk)
    return digest.hexdigest()


def visual_hash_file(path: str) -> str:
    """Return a compact difference hash that ignores insignificant video-frame noise."""
    with Image.open(path) as image:
        gray = image.convert("L").resize((9, 8), Image.Resampling.BILINEAR)
        pixels = list(gray.get_flattened_data())
    value = 0
    for row in range(8):
        offset = row * 9
        for column in range(8):
            value = (value << 1) | int(pixels[offset + column] > pixels[offset + column + 1])
    return f"{value:016x}"


def visual_hash_distance(left: str, right: str) -> int:
    """Return the Hamming distance between two 64-bit visual hashes."""
    return (int(left, 16) ^ int(right, 16)).bit_count()


def png_pixel_size(path: str) -> tuple[int, int]:
    with Image.open(path) as image:
        return image.size


def detect_iphone_in_use(path: str) -> bool:
    """True when the mirror window is the 'iPhone in Use / Lock your iPhone' chrome."""
    with Image.open(path) as image:
        small = image.convert("RGB").resize((64, 128))
        raw = small.tobytes()
    pixels = [(raw[index], raw[index + 1], raw[index + 2]) for index in range(0, len(raw), 3)]
    count = len(pixels)
    if count == 0:
        return False
    lums = [(red + green + blue) / 3.0 for red, green, blue in pixels]
    mean = sum(lums) / count
    variance = sum((value - mean) ** 2 for value in lums) / count
    stddev = variance**0.5
    saturated = sum(1 for red, green, blue in pixels if max(red, green, blue) - min(red, green, blue) > 50)
    return stddev < 32 and 18 <= mean <= 70 and saturated / count < 0.12


def annotate_screenshot(result: dict[str, Any], path: str) -> dict[str, Any]:
    width, height = png_pixel_size(path)
    result["pngWidth"] = width
    result["pngHeight"] = height
    result["sha256"] = sha256_file(path)
    result["visualHash"] = visual_hash_file(path)
    result["iphoneInUseHeuristic"] = detect_iphone_in_use(path)
    result["iphoneInUse"] = False
    return result


def blocked_reason_from_ocr(matches: list[dict[str, Any]], *, iphone_in_use: bool) -> str | None:
    """Classify known host-side blocking screens without confusing ordinary iOS UI."""
    del iphone_in_use  # Kept for API compatibility; the low-variance heuristic alone is not decisive.
    combined = " ".join(str(match.get("text") or "") for match in matches)
    normalized = " ".join(combined.casefold().split())
    for marker, reason in _BLOCKED_TEXT_MARKERS:
        if marker in normalized:
            return reason
    return None


def _in_range(value: int, target: int, tolerance: int) -> bool:
    return abs(value - target) <= tolerance


def find_pixels(
    path: str,
    *,
    red: int | None = None,
    green: int | None = None,
    blue: int | None = None,
    tolerance: int = 40,
    min_lum: int | None = None,
    x0: float = 0.0,
    y0: float = 0.0,
    x1: float = 1.0,
    y1: float = 1.0,
    min_pixels: int = 20,
) -> dict[str, Any]:
    """Return the centroid of matching pixels in normalized 0-1 screenshot space."""
    with Image.open(path) as image:
        rgb = image.convert("RGB")
        width, height = rgb.size
        left = max(0, min(width - 1, int(x0 * width)))
        top = max(0, min(height - 1, int(y0 * height)))
        right = max(left + 1, min(width, int(x1 * width)))
        bottom = max(top + 1, min(height, int(y1 * height)))
        crop = rgb.crop((left, top, right, bottom))
        pixels = crop.load()
        crop_w, crop_h = crop.size

    xs: list[int] = []
    ys: list[int] = []
    for local_y in range(crop_h):
        for local_x in range(crop_w):
            pixel_r, pixel_g, pixel_b = pixels[local_x, local_y]
            if min_lum is not None:
                if (pixel_r + pixel_g + pixel_b) / 3 < min_lum:
                    continue
            elif (
                red is None
                or green is None
                or blue is None
                or not (
                    _in_range(pixel_r, red, tolerance)
                    and _in_range(pixel_g, green, tolerance)
                    and _in_range(pixel_b, blue, tolerance)
                )
            ):
                continue
            xs.append(left + local_x)
            ys.append(top + local_y)

    found = len(xs) >= min_pixels
    if not found:
        return {
            "found": False,
            "n": len(xs),
            "cx": None,
            "cy": None,
            "bbox": None,
        }
    min_x, max_x = min(xs), max(xs)
    min_y, max_y = min(ys), max(ys)
    return {
        "found": True,
        "n": len(xs),
        "cx": (sum(xs) / len(xs)) / width,
        "cy": (sum(ys) / len(ys)) / height,
        "bbox": {
            "x0": min_x / width,
            "y0": min_y / height,
            "x1": max_x / width,
            "y1": max_y / height,
        },
    }
