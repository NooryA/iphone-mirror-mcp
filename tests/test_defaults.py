import inspect

from typing import get_args

from iphone_mirror_mcp.server import (
    Mode,
    find_bright,
    find_color,
    find_text,
    press_key,
    scroll,
    swipe,
    tap,
    tap_and_see,
    tap_label,
    type_text,
    wait_for_change,
)


def test_pointing_and_typing_defaults() -> None:
    assert inspect.signature(tap).parameters["mode"].default == "skylight"
    assert inspect.signature(swipe).parameters["mode"].default == "hid"
    assert inspect.signature(type_text).parameters["mode"].default == "hid"
    assert inspect.signature(press_key).parameters["mode"].default == "hid"


def test_tap_modes_default_to_skylight() -> None:
    assert set(get_args(Mode)) == {"background", "hid", "skylight"}
    assert inspect.signature(tap).parameters["mode"].default == "skylight"
    assert inspect.signature(tap_and_see).parameters["mode"].default == "skylight"
    assert inspect.signature(tap_label).parameters["mode"].default == "skylight"


def test_new_tools_have_sane_defaults() -> None:
    assert inspect.signature(tap_and_see).parameters["settle_ms"].default == 300
    assert inspect.signature(wait_for_change).parameters["timeout_ms"].default == 8000
    assert inspect.signature(find_color).parameters["tolerance"].default == 40
    assert inspect.signature(find_bright).parameters["min_lum"].default == 200
    assert inspect.signature(find_text).parameters["limit"].default == 8
    assert inspect.signature(scroll).parameters["delta"].default == -12
    assert inspect.signature(tap_label).parameters["settle_ms"].default == 300
