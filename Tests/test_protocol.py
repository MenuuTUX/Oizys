"""Ridge control framing and EDID parsing.

The EDID parser is the one place where bytes from the dock drive a length and a memcpy, so
it gets generated malformed input as well as valid. Hypothesis shrinks any failure to the
smallest reply that still breaks it, which is the difference between "some mutation of
20,000 crashed it" and "byte 148 set to 0xff crashes it".
"""
import ctypes

import pytest
from hypothesis import HealthCheck, given, settings
from hypothesis import strategies as st

from Support import oizyscore as core

EDID_OFFSET = 22
MAGIC = bytes([0x00, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x00])


def build_reply(extension_blocks: int = 0) -> bytes:
    """A structurally valid Ridge EDID reply with correct block checksums."""
    blocks = extension_blocks + 1
    out = bytearray(EDID_OFFSET + blocks * 128)
    out[0:2] = (0x0114).to_bytes(2, "little")
    out[2:4] = (0x0021).to_bytes(2, "little")
    out[EDID_OFFSET:EDID_OFFSET + 8] = MAGIC
    out[EDID_OFFSET + 126] = extension_blocks
    out[EDID_OFFSET + 8:EDID_OFFSET + 10] = bytes([0x10, 0xAC])  # "DEL"
    for block in range(blocks):
        start = EDID_OFFSET + block * 128
        out[start + 127] = (-sum(out[start:start + 127])) & 0xFF
    return bytes(out)


def parse(reply: bytes, capacity: int = 512):
    out = core.buffer(capacity)
    length = ctypes.c_size_t(0)
    status = core.lib.oizys_dl3_parse_ridge_edid(
        core.as_u8(reply), len(reply),
        ctypes.cast(out, ctypes.POINTER(ctypes.c_uint8)), capacity, ctypes.byref(length))
    return status, length.value, bytes(out[:length.value])


@pytest.mark.parametrize("extensions,expected", [(0, 128), (1, 256)])
def test_a_well_formed_reply_parses(extensions, expected):
    status, length, edid = parse(build_reply(extensions))
    assert status == 0, "a valid EDID was rejected"
    assert length == expected
    assert edid[:8] == MAGIC


@given(st.integers(0, len(build_reply()) - 1))
@settings(max_examples=80, deadline=None)
def test_truncation_is_always_rejected(cut):
    status, length, _ = parse(build_reply()[:cut])
    assert status != 0, f"a reply truncated to {cut} bytes was accepted"
    assert length == 0, "edid_len must be cleared on rejection"


@pytest.mark.parametrize("index,label", [
    (0, "message id"),
    (EDID_OFFSET + 3, "EDID magic"),
    (EDID_OFFSET + 40, "block checksum"),
])
def test_corrupting_a_required_field_is_rejected(index, label):
    reply = bytearray(build_reply())
    reply[index] ^= 0xFF
    status, _, _ = parse(bytes(reply))
    assert status != 0, f"a corrupted {label} was accepted"


def test_a_block_count_larger_than_the_payload_is_rejected():
    """This field drives the memcpy length. Unchecked it is a straight buffer overflow."""
    reply = bytearray(build_reply())
    reply[EDID_OFFSET + 126] = 0xFF
    status, _, _ = parse(bytes(reply))
    assert status != 0, "a block count the payload cannot back was accepted"


def test_a_destination_smaller_than_the_edid_is_rejected():
    status, _, _ = parse(build_reply(1), capacity=128)
    assert status != 0, "a 256-byte EDID was written into a 128-byte buffer"


@given(st.lists(st.tuples(st.integers(0, len(build_reply()) - 1), st.integers(0, 255)),
                min_size=1, max_size=8))
@settings(max_examples=1500, deadline=None,
          suppress_health_check=[HealthCheck.too_slow])
def test_no_mutation_makes_the_parser_lie(mutations):
    """Whatever the dock sends, the parser either refuses or reports a length its payload
    can actually back. Run under a sanitiser build this also covers reads past the end."""
    reply = bytearray(build_reply())
    for index, value in mutations:
        reply[index] = value
    status, length, _ = parse(bytes(reply))
    if status == 0:
        assert length in (128, 256), f"accepted a reply reporting {length} bytes"
        assert length <= len(reply) - EDID_OFFSET, "accepted a length the payload cannot back"
    else:
        assert length == 0, "edid_len left non-zero after a rejection"


def test_header_layout_is_stable():
    header = core.buffer(16)
    core.lib.oizys_dl3_header(ctypes.cast(header, ctypes.POINTER(ctypes.c_uint8)),
                              0x11223344, 0x5566, 0x7788, 0x99AABBCC, 32)
    assert bytes(header).hex() == "00002c00443322116655887 7ccbbaa99".replace(" ", "")


def test_set_mode_addresses_the_head_it_was_asked_for():
    """off22 is the zero-based head. off23 is not a head at all: it picks the line count, and
    the dock reads 0 as 720 lines, 1 as 1440 and 2 as the 1080 this timing asks for. Reading
    off23 as a head number sizes the buffer 2/3 or 4/3 wrong and the dock falls back with the
    panel dark."""
    for head in (0, 1):
        mode = core.buffer(80)
        pointer = ctypes.cast(mode, ctypes.POINTER(ctypes.c_uint8))
        assert core.lib.oizys_dl3_set_mode_1080p60(pointer, 80, 0, head) == 80
        assert bytes(mode)[22] == head
        assert bytes(mode)[23] == 2


def test_size_field_is_the_body_plus_twelve():
    header = core.buffer(16)
    for body in (0, 1, 64, 1024):
        core.lib.oizys_dl3_header(ctypes.cast(header, ctypes.POINTER(ctypes.c_uint8)),
                                  0, 0, 0, 0, body)
        assert int.from_bytes(bytes(header)[2:4], "little") == body + 12


BUILDERS = {
    "init_0": lambda out, cap: core.lib.oizys_dl3_init_0(out, cap),
    "init_25": lambda out, cap: core.lib.oizys_dl3_init_25(out, cap),
    "init_4_probe": lambda out, cap: core.lib.oizys_dl3_init_4_probe(out, cap),
    "session_ack": lambda out, cap: core.lib.oizys_hdcp_session_ack(out, cap, 1, 2),
    "ake_init": lambda out, cap: core.lib.oizys_hdcp_ake_init(out, cap, 1, 2,
                                                              core.as_u8(bytes(8))),
    "ake_txinfo": lambda out, cap: core.lib.oizys_hdcp_ake_txinfo(out, cap, 1, 2),
    "ake_no_stored_km": lambda out, cap: core.lib.oizys_hdcp_ake_no_stored_km(
        out, cap, 1, 2, core.as_u8(bytes(128))),
    "lc_init": lambda out, cap: core.lib.oizys_hdcp_lc_init(out, cap, 1, 2, core.as_u8(bytes(8))),
    "ske_send_eks": lambda out, cap: core.lib.oizys_hdcp_ske_send_eks(
        out, cap, 1, 2, core.as_u8(bytes(16)), core.as_u8(bytes(8))),
    "stream_manage": lambda out, cap: core.lib.oizys_hdcp_stream_manage(out, cap, 1, 2),
    "set_mode_1080p60": lambda out, cap: core.lib.oizys_dl3_set_mode_1080p60(out, cap, 0, 0),
}


@pytest.mark.parametrize("name", sorted(BUILDERS))
def test_frame_builders_never_write_past_their_capacity(name):
    """Every builder takes a capacity. A guard region past the end catches one that writes
    first and checks afterwards."""
    builder = BUILDERS[name]
    ample = core.buffer(4096)
    pointer = ctypes.cast(ample, ctypes.POINTER(ctypes.c_uint8))
    length = builder(pointer, 4096)
    assert length >= 16, f"{name} produced {length} bytes, shorter than a header"

    for capacity in range(max(0, length - 4), length):
        guarded = core.buffer(4096, fill=0xA5)
        pointer = ctypes.cast(guarded, ctypes.POINTER(ctypes.c_uint8))
        assert builder(pointer, capacity) == 0, f"{name} accepted a {capacity}-byte buffer"
        assert all(guarded[i] == 0xA5 for i in range(capacity, 4096)), \
            f"{name} wrote past a {capacity}-byte capacity"


@given(st.binary(min_size=16, max_size=16))
@settings(max_examples=200, deadline=None)
def test_cp_session_key_whitening_is_reversible(raw):
    live, back = core.buffer(16), core.buffer(16)
    p = ctypes.POINTER(ctypes.c_uint8)
    core.lib.oizys_cp_session_key(core.as_u8(raw), ctypes.cast(live, p))
    core.lib.oizys_cp_session_key(core.as_u8(bytes(live)), ctypes.cast(back, p))
    assert bytes(back) == raw
    assert bytes(live) != raw, "whitening was a no-op"


def test_only_ridge_has_a_profile():
    profile = core.lib.oizys_dl3_profile(0x6000)
    assert profile, "the Ridge profile is missing"
    assert profile.contents.head_count == 2
    assert profile.contents.video_endpoint[0] == 0x08
    assert profile.contents.video_endpoint[1] == 0x0B
    assert profile.contents.ddc_selector[0] != profile.contents.ddc_selector[1]
    for unknown in (0x0000, 0xFFFF, 0x6001):
        assert not core.lib.oizys_dl3_profile(unknown), f"{unknown:#06x} returned a profile"
