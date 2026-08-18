from __future__ import annotations

import hashlib
from typing import Any

from PIL import Image

VISUAL_SIGNATURE_VERSION = "rgb16"
VISUAL_SIGNATURE_SIZE = 16

_BLOCKED_TEXT_MARKERS = (
    ("lock your iphone to connect", "iphone_in_use"),
    ("iphone in use", "iphone_in_use"),
    ("icloud signed out", "icloud_signed_out"),
    ("sign in to icloud to continue", "icloud_signed_out"),
    ("welcome to iphone mirroring", "setup_required"),
    ("iphone mirroring not available", "mirroring_unavailable"),
    ("unable to connect to iphone", "connection_unavailable"),
    ("connection paused", "connection_paused"),
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


def visual_signature_file(path: str) -> str:
    """Sample absolute RGB values so flat/color-only transitions remain visible."""
    with Image.open(path) as image:
        rgb = image.convert("RGB")
        width, height = rgb.size
        pixels = rgb.load()
        samples = bytearray()
        for row in range(VISUAL_SIGNATURE_SIZE):
            y = min(height - 1, int((row + 0.5) * height / VISUAL_SIGNATURE_SIZE))
            for column in range(VISUAL_SIGNATURE_SIZE):
                x = min(width - 1, int((column + 0.5) * width / VISUAL_SIGNATURE_SIZE))
                samples.extend(pixels[x, y])
    return f"{VISUAL_SIGNATURE_VERSION}:{samples.hex()}"


def visual_signature_distance(left: str, right: str) -> float:
    """Return mean absolute RGB difference between versioned visual signatures."""
    prefix = f"{VISUAL_SIGNATURE_VERSION}:"
    if not left.startswith(prefix) or not right.startswith(prefix):
        raise ValueError(f"visual signatures must use the {VISUAL_SIGNATURE_VERSION} format")
    try:
        left_bytes = bytes.fromhex(left[len(prefix) :])
        right_bytes = bytes.fromhex(right[len(prefix) :])
    except ValueError as exc:
        raise ValueError("visual signature contains invalid hexadecimal data") from exc
    expected_length = VISUAL_SIGNATURE_SIZE * VISUAL_SIGNATURE_SIZE * 3
    if len(left_bytes) != expected_length or len(right_bytes) != expected_length:
        raise ValueError(f"visual signatures must contain {expected_length} RGB bytes")
    return sum(abs(a - b) for a, b in zip(left_bytes, right_bytes, strict=True)) / expected_length


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
    result["visualSignature"] = visual_signature_file(path)
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

    count = 0
    sum_x = 0
    sum_y = 0
    min_x = width
    max_x = -1
    min_y = height
    max_y = -1
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
            x = left + local_x
            y = top + local_y
            count += 1
            sum_x += x
            sum_y += y
            min_x = min(min_x, x)
            max_x = max(max_x, x)
            min_y = min(min_y, y)
            max_y = max(max_y, y)

    found = count >= min_pixels
    if not found:
        return {
            "found": False,
            "n": count,
            "cx": None,
            "cy": None,
            "bbox": None,
        }
    return {
        "found": True,
        "n": count,
        "cx": (sum_x / count) / width,
        "cy": (sum_y / count) / height,
        "bbox": {
            "x0": min_x / width,
            "y0": min_y / height,
            "x1": max_x / width,
            "y1": max_y / height,
        },
    }
