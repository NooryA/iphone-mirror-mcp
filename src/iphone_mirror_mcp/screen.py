from __future__ import annotations

import hashlib
import io
import math
from dataclasses import dataclass
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

# Vision boxes for neighboring glyph runs can overlap slightly. Bound that tolerance by text
# height so genuine splits join without accepting nested or duplicate observations.
_MAXIMUM_ADJACENT_BOX_OVERLAP_SCALE = 0.25


@dataclass(frozen=True)
class _PositionedText:
    text: str
    x0: float
    y0: float
    x1: float
    y1: float

    @property
    def center_y(self) -> float:
        return (self.y0 + self.y1) / 2

    @property
    def height(self) -> float:
        return self.y1 - self.y0


def sha256_file(path: str) -> str:
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for chunk in iter(lambda: handle.read(65536), b""):
            digest.update(chunk)
    return digest.hexdigest()


def visual_hash_file(path: str) -> str:
    """Return a compact difference hash that ignores insignificant video-frame noise."""
    with Image.open(path) as image:
        return _visual_hash_image(image)


def _visual_hash_image(image: Image.Image) -> str:
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
        return _visual_signature_image(image)


def _visual_signature_image(image: Image.Image) -> str:
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
        return _detect_iphone_in_use_image(image)


def _detect_iphone_in_use_image(image: Image.Image) -> bool:
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
    with open(path, "rb") as handle:
        png = handle.read()
    with Image.open(io.BytesIO(png)) as image:
        image.load()
        width, height = image.size
        visual_hash = _visual_hash_image(image)
        visual_signature = _visual_signature_image(image)
        iphone_in_use_heuristic = _detect_iphone_in_use_image(image)
    result["pngWidth"] = width
    result["pngHeight"] = height
    result["sha256"] = hashlib.sha256(png).hexdigest()
    result["visualHash"] = visual_hash
    result["visualSignature"] = visual_signature
    result["iphoneInUseHeuristic"] = iphone_in_use_heuristic
    result.setdefault("iphoneInUse", False)
    return result


def blocked_reason_from_ocr(matches: list[dict[str, Any]], *, iphone_in_use: bool) -> str | None:
    """Classify known host-side blocking screens without confusing ordinary iOS UI."""
    del iphone_in_use  # Kept for API compatibility; the low-variance heuristic alone is not decisive.
    normalized_texts = [_normalize_text(str(match.get("text") or "")) for match in matches]
    for text in normalized_texts:
        if reason := _blocked_reason_in_text(text):
            return reason

    # Mirror the native classifier: split OCR observations may form a warning only when their
    # boxes are adjacent in reading order. Global concatenation can falsely combine unrelated UI.
    for run in _adjacent_text_runs(matches):
        if reason := _blocked_reason_in_text(" ".join(item.text for item in run)):
            return reason
    return None


def _normalize_text(text: str) -> str:
    return " ".join(text.casefold().split())


def _blocked_reason_in_text(text: str) -> str | None:
    for marker, reason in _BLOCKED_TEXT_MARKERS:
        if marker in text:
            return reason
    return None


def _positioned_text(match: dict[str, Any]) -> _PositionedText | None:
    text = _normalize_text(str(match.get("text") or ""))
    bbox = match.get("bbox")
    if not text or not isinstance(bbox, dict):
        return None
    values = [bbox.get(key) for key in ("x0", "y0", "x1", "y1")]
    if any(isinstance(value, bool) or not isinstance(value, (int, float)) for value in values):
        return None
    x0, y0, x1, y1 = (float(value) for value in values)
    if not all(math.isfinite(value) for value in (x0, y0, x1, y1)):
        return None
    if not (0 <= x0 < x1 <= 1 and 0 <= y0 < y1 <= 1):
        return None
    return _PositionedText(text=text, x0=x0, y0=y0, x1=x1, y1=y1)


def _adjacent_text_runs(matches: list[dict[str, Any]]) -> list[list[_PositionedText]]:
    positioned = sorted(
        filter(None, (_positioned_text(match) for match in matches)),
        key=lambda item: (item.center_y, item.x0),
    )
    lines: list[list[_PositionedText]] = []
    for item in positioned:
        if lines:
            center_y = sum(existing.center_y for existing in lines[-1]) / len(lines[-1])
            mean_height = sum(existing.height for existing in lines[-1]) / len(lines[-1])
            if abs(item.center_y - center_y) <= 0.6 * max(item.height, mean_height):
                lines[-1].append(item)
                continue
        lines.append([item])
    for line in lines:
        line.sort(key=lambda item: item.x0)

    runs: list[list[_PositionedText]] = []
    previous_line: list[_PositionedText] | None = None
    for line in lines:
        segments: list[list[_PositionedText]] = []
        for item in line:
            if segments and _horizontally_adjacent(segments[-1][-1], item):
                segments[-1].append(item)
            else:
                segments.append([item])
        if previous_line and runs and segments and _wraps_from(previous_line, line):
            runs[-1].extend(segments.pop(0))
        runs.extend(segments)
        previous_line = line
    return runs


def _horizontally_adjacent(left: _PositionedText, right: _PositionedText) -> bool:
    minimum_gap = -_MAXIMUM_ADJACENT_BOX_OVERLAP_SCALE * min(left.height, right.height)
    maximum_gap = max(0.015, 1.75 * max(left.height, right.height))
    gap = right.x0 - left.x1
    return minimum_gap <= gap <= maximum_gap


def _wraps_from(upper: list[_PositionedText], lower: list[_PositionedText]) -> bool:
    upper_height = sum(item.height for item in upper) / len(upper)
    lower_height = sum(item.height for item in lower) / len(lower)
    upper_x0 = min(item.x0 for item in upper)
    upper_x1 = max(item.x1 for item in upper)
    lower_x0 = min(item.x0 for item in lower)
    lower_x1 = max(item.x1 for item in lower)
    upper_center_y = sum(item.center_y for item in upper) / len(upper)
    lower_center_y = sum(item.center_y for item in lower) / len(lower)
    if lower_center_y <= upper_center_y:
        return False
    vertical_gap = min(item.y0 for item in lower) - max(item.y1 for item in upper)
    minimum_vertical_gap = -_MAXIMUM_ADJACENT_BOX_OVERLAP_SCALE * min(upper_height, lower_height)
    maximum_vertical_gap = max(0.02, 1.5 * max(upper_height, lower_height))
    if not minimum_vertical_gap <= vertical_gap <= maximum_vertical_gap:
        return False
    maximum_horizontal_gap = max(0.03, 2 * max(upper_height, lower_height))
    return lower_x0 <= upper_x1 + maximum_horizontal_gap and lower_x1 >= upper_x0 - maximum_horizontal_gap


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
