from iphone_mirror_mcp.geometry import (
    Rect,
    assert_inside_window,
    clamp01,
    content_rect,
    normalized_to_global,
    window_list_to_local,
)
import pytest


def test_clamp01_edges() -> None:
    assert clamp01(-0.2) == 0.0
    assert clamp01(1.4) == 1.0
    assert clamp01(0.25) == 0.25


def test_content_rect_subtracts_titlebar() -> None:
    window = Rect(x=100, y=200, width=316, height=696)
    content = content_rect(window, titlebar=52)
    assert content.x == 100
    assert content.y == 252
    assert content.width == 316
    assert content.height == 644


def test_normalized_corners_map_inside_content() -> None:
    window = Rect(x=1067, y=274, width=316, height=696)
    content = content_rect(window, titlebar=52)
    tl = normalized_to_global(0, 0, content)
    br = normalized_to_global(1, 1, content)
    assert tl == (content.x, content.y)
    assert br == (content.max_x, content.max_y)
    assert_inside_window(*tl, window)
    assert_inside_window(*br, window)


def test_center_tap_is_inside_window() -> None:
    window = Rect(x=1067, y=274, width=316, height=696)
    content = content_rect(window, titlebar=52)
    x, y = normalized_to_global(0.5, 0.5, content)
    assert_inside_window(x, y, window)
    assert abs(x - (content.x + content.width / 2)) < 0.01


def test_rejects_point_outside_window() -> None:
    window = Rect(x=10, y=10, width=100, height=100)
    with pytest.raises(ValueError, match="outside"):
        assert_inside_window(5, 50, window)


def test_empty_content_rect_raises() -> None:
    window = Rect(x=0, y=0, width=40, height=40)
    with pytest.raises(ValueError, match="empty"):
        content_rect(window, titlebar=40)


def test_window_list_to_local_matches_cta_click() -> None:
    window = Rect(x=1067, y=274, width=316, height=696)
    content = content_rect(window, titlebar=52)
    px, py = normalized_to_global(0.5, 0.88, content)
    local_x, local_y = window_list_to_local(px, py, window)
    assert abs(local_x - 158) < 0.01
    assert 70 < local_y < 90


def test_window_list_to_local_top_left_is_window_height() -> None:
    window = Rect(x=100, y=200, width=316, height=696)
    local_x, local_y = window_list_to_local(100, 200, window)
    assert local_x == 0
    assert local_y == 696
