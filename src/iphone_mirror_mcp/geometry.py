from __future__ import annotations

import math
from dataclasses import dataclass


@dataclass(frozen=True)
class Rect:
    x: float
    y: float
    width: float
    height: float

    @property
    def max_x(self) -> float:
        return self.x + self.width

    @property
    def max_y(self) -> float:
        return self.y + self.height

    def contains(self, px: float, py: float, *, slop: float = 0.5) -> bool:
        return self.x - slop <= px < self.max_x + slop and self.y - slop <= py < self.max_y + slop


def clamp01(value: float) -> float:
    if value < 0.0:
        return 0.0
    if value > 1.0:
        return 1.0
    return value


def require_normalized(value: float, *, name: str) -> float:
    """Validate an action coordinate instead of turning a bad value into a click."""
    if not math.isfinite(value) or not 0.0 <= value <= 1.0:
        raise ValueError(f"{name} must be a finite number between 0 and 1")
    return value


def content_rect(
    window: Rect,
    *,
    titlebar: float = 52.0,
    inset_left: float = 0.0,
    inset_right: float = 0.0,
    inset_bottom: float = 0.0,
) -> Rect:
    values = {
        "window.x": window.x,
        "window.y": window.y,
        "window.width": window.width,
        "window.height": window.height,
        "titlebar": titlebar,
        "inset_left": inset_left,
        "inset_right": inset_right,
        "inset_bottom": inset_bottom,
    }
    for name, value in values.items():
        if not math.isfinite(value):
            raise ValueError(f"{name} must be finite")
    if window.width <= 1 or window.height <= 1:
        raise ValueError("window dimensions must be greater than 1 point")
    top = max(0.0, titlebar)
    left = max(0.0, inset_left)
    right = max(0.0, inset_right)
    bottom = max(0.0, inset_bottom)
    width = window.width - left - right
    height = window.height - top - bottom
    if width <= 1 or height <= 1:
        raise ValueError("content rect is empty; check titlebar/insets against window size")
    return Rect(
        x=window.x + left,
        y=window.y + top,
        width=width,
        height=height,
    )


def normalized_to_global(
    nx: float,
    ny: float,
    content: Rect,
) -> tuple[float, float]:
    nx = require_normalized(nx, name="x")
    ny = require_normalized(ny, name="y")
    # Quartz window bounds are half-open. Keep normalized 1.0 half a point inside
    # so an edge action cannot spill into an adjacent window or display.
    return (
        min(content.max_x - 0.5, content.x + nx * content.width),
        min(content.max_y - 0.5, content.y + ny * content.height),
    )


def window_list_to_local(px: float, py: float, window: Rect) -> tuple[float, float]:
    """CGWindowList / CGWarp (top-left) → NSEvent window coords (bottom-left of window)."""
    return (px - window.x, window.max_y - py)


def assert_inside_window(px: float, py: float, window: Rect) -> None:
    if not window.contains(px, py, slop=0):
        raise ValueError(
            f"point ({px:.1f}, {py:.1f}) is outside the iPhone Mirroring window "
            f"({window.x:.0f},{window.y:.0f} {window.width:.0f}x{window.height:.0f})"
        )
