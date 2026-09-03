"""The configuration parser, clamp and round-trip.

config.c is 576 regions of pure C: one table drives parsing, clamping, listing and
writing, and every field type (int, double, bool, the head bitmask, the head reference
and the string) has its own path through it. None of it needs the dock, so all of it is
reachable through the library once the backing file is pointed somewhere disposable.

OIZYS_CONFIG_PATH must be set before the library is first loaded, because the path is
cached on first use. conftest imports the library at collection time, so the environment
is set here at import, before the fixture forces a reload onto the temp file.
"""
import ctypes
import io
import os
import pathlib
import tempfile

import pytest

from Support import oizyscore as core

_CONFIG_DIR = tempfile.TemporaryDirectory(prefix="oizys-config-test-")
os.environ["OIZYS_CONFIG_PATH"] = str(pathlib.Path(_CONFIG_DIR.name) / "config.json")


@pytest.fixture(autouse=True)
def clean_config():
    """Every test starts from defaults on the disposable file."""
    core.lib.oizys_config_reset()
    core.lib.oizys_config_reload()
    yield
    core.lib.oizys_config_reset()


def get(key):
    buf = ctypes.create_string_buffer(64)
    rc = core.lib.oizys_config_get(key.encode(), buf, len(buf))
    return rc, buf.value.decode()


def set_(key, value):
    return core.lib.oizys_config_set(key.encode(), str(value).encode())


def test_the_library_selftest_passes():
    assert core.lib.oizys_config_selftest() == 0


def test_defaults_round_trip():
    for key, default in [("head.width", "1920"), ("capture.fps", "60"),
                         ("control.poll_ms", "13"), ("log.level", "info"),
                         ("heads.active", "left,right"), ("heads.native", "none")]:
        rc, value = get(key)
        assert rc == 0 and value == default, f"{key} default was {value!r}"


def test_set_then_get_persists_across_reload():
    assert set_("head.refresh_hz", "75") == 0
    core.lib.oizys_config_reload()
    rc, value = get("head.refresh_hz")
    assert rc == 0 and value.startswith("75")


@pytest.mark.parametrize("key,low,high,below,above", [
    ("control.poll_ms", 8, 50, 5, 900),
    ("head.width", 640, 7680, 100, 99999),
    ("dock.buffers", 2, 3, 1, 9),
    ("capture.queue_depth", 1, 8, 0, 64),
])
def test_out_of_range_values_clamp_not_reject(key, low, high, below, above):
    assert set_(key, below) == 0
    _, value = get(key)
    assert int(value) == low, f"{key}={below} should clamp up to {low}, got {value}"
    assert set_(key, above) == 0
    _, value = get(key)
    assert int(value) == high, f"{key}={above} should clamp down to {high}, got {value}"


def test_unknown_key_is_minus_one():
    assert set_("no.such.key", "1") == -1
    rc, _ = get("no.such.key")
    assert rc != 0


def test_unparseable_value_is_minus_two():
    assert set_("head.width", "not-a-number") == -2
    assert set_("capture.dump_frames", "maybe") == -2
    assert set_("head.refresh_hz", "") == -2


def test_head_bitmask_and_reference_spellings():
    for spelling, active_left, active_right in [
        ("left", 1, 0), ("right", 0, 1), ("left,right", 1, 1)]:
        assert set_("heads.active", spelling) == 0
        core.lib.oizys_config_reload()
        assert core.lib.oizys_config_head_active(0) == active_left
        assert core.lib.oizys_config_head_active(1) == active_right
    assert set_("heads.native", "left") == 0
    assert set_("heads.native", "none") == 0
    assert set_("heads.active", "middle") == -2


def test_bool_accepts_the_usual_spellings():
    for truthy in ("true", "1", "yes", "on"):
        assert set_("displaylink.auto_stop", truthy) == 0
        _, value = get("displaylink.auto_stop")
        assert value in ("true", "1", "yes", "on", "True")
    for falsy in ("false", "0", "no", "off"):
        assert set_("displaylink.auto_stop", falsy) == 0


def test_string_field_is_length_bounded():
    assert set_("log.level", "debug") == 0
    _, value = get("log.level")
    assert value == "debug"
    # Overlong values must not overflow the fixed field; either rejected or truncated.
    long = "x" * 200
    rc = set_("log.level", long)
    _, value = get("log.level")
    assert len(value) < 16


def test_reset_returns_to_defaults():
    set_("capture.fps", "30")
    assert core.lib.oizys_config_reset() == 0
    core.lib.oizys_config_reload()
    _, value = get("capture.fps")
    assert value == "60"


def test_path_reports_the_override():
    assert core.lib.oizys_config_path().decode() == os.environ["OIZYS_CONFIG_PATH"]


def test_print_lists_every_key():
    # oizys_config_print writes to a FILE*; drive it through a real temp file. Every
    # libc call here needs argtypes: without them ctypes passes a FILE* as a C int and
    # truncates it to 32 bits, which segfaults inside fclose rather than failing the
    # assert.
    libc = ctypes.CDLL(None)
    libc.fopen.restype = ctypes.c_void_p
    libc.fopen.argtypes = [ctypes.c_char_p, ctypes.c_char_p]
    libc.fclose.restype = ctypes.c_int
    libc.fclose.argtypes = [ctypes.c_void_p]
    with tempfile.NamedTemporaryFile("w+", suffix=".txt", delete=False) as handle:
        path = handle.name
    try:
        stream = libc.fopen(path.encode(), b"w")
        assert stream, "could not open the temp file for the C side to write"
        core.lib.oizys_config_print(ctypes.c_void_p(stream))
        libc.fclose(ctypes.c_void_p(stream))
        text = pathlib.Path(path).read_text()
    finally:
        os.unlink(path)
    for key in ("head.width", "control.poll_ms", "log.level", "dock.buffers"):
        assert key in text


def test_free_text_keeps_a_name_with_spaces_whole():
    # A device name is whatever its owner typed. It has to survive the write, the reload
    # and the listing intact: the menu bar reads a name back out of oizys_config_print,
    # and a value clipped at the first space picks a different iPad or none at all.
    name = "shib's iPad Pro"
    assert set_("sidecar.device", name) == 0
    core.lib.oizys_config_reload()
    rc, value = get("sidecar.device")
    assert rc == 0 and value == name
    assert set_("sidecar.device", "") == 0
    _, value = get("sidecar.device")
    assert value == ""


def test_new_display_and_sidecar_defaults():
    # Putting other displays' resolutions back is on: the bug it prevents is silent and
    # permanent. Connecting an iPad by itself is off until somebody asks for it.
    for key, default in [("display.keep_modes", "true"),
                         ("sidecar.auto_connect", "false"),
                         ("sidecar.require_desk", "true"),
                         ("sidecar.device", "")]:
        rc, value = get(key)
        assert rc == 0 and value == default, f"{key} default was {value!r}"
