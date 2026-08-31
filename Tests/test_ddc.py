"""Reject ambiguous monitor identities and malformed DDC replies without touching hardware."""
import ctypes
import pathlib
import subprocess

import pytest
from Support.native_coverage import flags

ROOT = pathlib.Path(__file__).resolve().parent.parent


@pytest.fixture(scope="module")
def ddc(tmp_path_factory):
    output = tmp_path_factory.mktemp("ddc") / "ddc-tests.dylib"
    subprocess.run([
        "xcrun", "clang", "-std=c11", "-dynamiclib",
        "-I", str(ROOT / "Sources/OizysCore/include"),
        str(ROOT / "Tests/Support/ddc_native_test.c"),
        "-framework", "Foundation", "-framework", "CoreGraphics", "-framework", "IOKit",
        *flags(output), "-o", str(output),
    ], check=True, capture_output=True, text=True)
    library = ctypes.CDLL(str(output))
    library.test_match.argtypes = [ctypes.c_char_p, ctypes.c_size_t,
                                  ctypes.POINTER(ctypes.c_uint32), ctypes.c_uint32]
    library.test_match.restype = ctypes.c_uint32
    library.test_reply.argtypes = [ctypes.c_char_p, ctypes.c_size_t]
    library.test_reply.restype = ctypes.c_int
    return library


def edid(serial=0x32483342):
    data = bytearray(128)
    data[:8] = bytes.fromhex("00 ff ff ff ff ff ff 00")
    data[8:12] = bytes.fromhex("10 ac 15 a1")
    data[12:16] = serial.to_bytes(4, "little")
    data[127] = -sum(data[:127]) & 255
    return bytes(data)


NATIVE = (0x10AC, 0xA115, 0x32483342, 0, 0)
DOCK = (0x10AC, 0xA115, 0x34583142, 0, 0)


def match(ddc, data, displays):
    fields = [field for display in displays for field in display]
    array = (ctypes.c_uint32 * len(fields))(*fields)
    return ddc.test_match(data, len(data), array, len(displays))


def test_two_identical_models_match_the_native_serial(ddc):
    assert match(ddc, edid(), [DOCK, NATIVE]) == 2
    assert match(ddc, edid(), [NATIVE, DOCK]) == 1


@pytest.mark.parametrize("displays", [
    [], [DOCK], [NATIVE, NATIVE], [(0x1234, *NATIVE[1:])],
    [(*NATIVE[:3], 1, 0)], [(*NATIVE[:3], 0, 1)],
])
def test_never_fall_back_to_an_unmatched_or_ambiguous_display(ddc, displays):
    assert match(ddc, edid(), displays) == 0


def test_missing_serial_must_still_have_a_unique_match(ddc):
    display = (*NATIVE[:2], 0, 0, 0)
    assert match(ddc, edid(0), [display]) == 1
    assert match(ddc, edid(0), [display, display]) == 0


def test_truncated_or_corrupted_edid_never_selects_a_display(ddc):
    data = edid()
    for length in range(128):
        assert match(ddc, data[:length], [NATIVE]) == 0
    for index in range(128):
        damaged = bytearray(data)
        damaged[index] ^= 1
        assert match(ddc, bytes(damaged), [NATIVE]) == 0


def test_ddc_reply_requires_complete_length_and_checksum(ddc):
    # Captured-form brightness reply: 50 / 100. Trailing I2C padding is allowed.
    reply = bytes.fromhex("6e 88 02 00 10 00 00 64 00 32 f2")
    assert ddc.test_reply(reply, len(reply)) == 1
    padded = reply + b"\0"
    assert ddc.test_reply(padded, len(padded)) == 1
    for length in range(len(reply)):
        assert ddc.test_reply(reply[:length], length) == 0
    for index in range(len(reply)):
        damaged = bytearray(reply)
        damaged[index] ^= 1
        assert ddc.test_reply(bytes(damaged), len(damaged)) == 0
    oversized = b"\x6e\xff" + b"\0" * 38
    assert ddc.test_reply(oversized, len(oversized)) == 0
