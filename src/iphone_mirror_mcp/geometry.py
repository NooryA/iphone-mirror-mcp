from __future__ import annotations

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
        return (
            self.x - slop <= px <= self.max_x + slop
            and self.y - slop <= py <= self.max_y + slop
        )


def clamp01(value: float) -> float:
    if value < 0.0:
        return 0.0
    if value > 1.0:
        return 1.0
    return value


def content_rect(
    window: Rect,
    *,
    titlebar: float = 52.0,
    inset_left: float = 0.0,
    inset_right: float = 0.0,
    inset_bottom: float = 0.0,
) -> Rect:
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
    nx = clamp01(nx)
    ny = clamp01(ny)
    return (content.x + nx * content.width, content.y + ny * content.height)


def window_list_to_local(px: float, py: float, window: Rect) -> tuple[float, float]:
    """CGWindowList / CGWarp (top-left) → NSEvent window coords (bottom-left of window)."""
    return (px - window.x, window.max_y - py)


def assert_inside_window(px: float, py: float, window: Rect) -> None:
    if not window.contains(px, py):
        raise ValueError(
            f"point ({px:.1f}, {py:.1f}) is outside the iPhone Mirroring window "
            f"({window.x:.0f},{window.y:.0f} {window.width:.0f}x{window.height:.0f})"
        )
