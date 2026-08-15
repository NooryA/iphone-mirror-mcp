import inspect

from iphone_mirror_mcp.server import (
    find_bright,
    find_color,
    press_key,
    swipe,
    tap,
    tap_and_see,
    type_text,
    wait_for_change,
)


def test_pointing_and_typing_default_to_hid() -> None:
    assert inspect.signature(tap).parameters["mode"].default == "hid"
    assert inspect.signature(swipe).parameters["mode"].default == "hid"
    assert inspect.signature(type_text).parameters["mode"].default == "hid"
    assert inspect.signature(press_key).parameters["mode"].default == "hid"


def test_new_tools_have_sane_defaults() -> None:
    assert inspect.signature(tap_and_see).parameters["settle_ms"].default == 450
    assert inspect.signature(wait_for_change).parameters["timeout_ms"].default == 8000
    assert inspect.signature(find_color).parameters["tolerance"].default == 40
    assert inspect.signature(find_bright).parameters["min_lum"].default == 200
