import inspect

from iphone_mirror_mcp.server import press_key, swipe, tap, type_text


def test_pointing_and_typing_default_to_hid() -> None:
    assert inspect.signature(tap).parameters["mode"].default == "hid"
    assert inspect.signature(swipe).parameters["mode"].default == "hid"
    assert inspect.signature(type_text).parameters["mode"].default == "hid"
    assert inspect.signature(press_key).parameters["mode"].default == "hid"
