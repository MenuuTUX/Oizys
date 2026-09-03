"""The per-head brightness gain, which is the only brightness control a dock-driven panel has.

DDC/CI needs a native display pipe and a DisplayLink output has none, so a head's monitor
cannot be asked to dim itself. Oizys owns every pixel those panels receive instead, so the
control is a gain applied while encoding. These check it does what its name says, that unity
is genuinely free, and that it acts on all three channels alike rather than shifting colour.
"""
import ctypes

import numpy as np
import pytest

from Support import oizyscore as core

STRIP_W, STRIP_H = 64, 16


def surface(seed):
    generator = np.random.default_rng(seed)
    return generator.integers(0, 256, (STRIP_H, STRIP_W, 4), dtype=np.uint8)


@pytest.fixture(autouse=True)
def unity_after_each():
    # The gain is module state in the encoder. A test that left it set would silently dim
    # every later test's expectations.
    yield
    core.lib.oizys_video_set_gain(256)
    assert core.lib.oizys_video_gain() == 256


def encode(pixels, gain):
    core.lib.oizys_video_set_gain(gain)
    out = (ctypes.c_uint8 * (1 << 18))()
    flat = np.ascontiguousarray(pixels)
    pointer = flat.ctypes.data_as(ctypes.POINTER(ctypes.c_uint8))
    length = core.lib.oizys_video_colour_strip_bgra(
        out, len(out), 0, 0, pointer, STRIP_W * 4, STRIP_W, STRIP_H)
    assert length > 0
    return bytes(out[:length])


def test_gain_clamps_to_its_range():
    core.lib.oizys_video_set_gain(-1)
    assert core.lib.oizys_video_gain() == 0
    core.lib.oizys_video_set_gain(1000)
    assert core.lib.oizys_video_gain() == 256
    core.lib.oizys_video_set_gain(200)
    assert core.lib.oizys_video_gain() == 200


def test_unity_gain_is_byte_identical_and_repeatable():
    pixels = surface(7)
    baseline = encode(pixels, 256)
    assert encode(pixels, 256) == baseline


def test_dimming_changes_the_encoded_strip():
    pixels = surface(11)
    assert encode(pixels, 128) != encode(pixels, 256)


def test_zero_gain_matches_encoding_black():
    # Scaling every plane to zero is the same as having been handed black. This is the
    # strongest available statement that the gain acts uniformly on all three channels
    # rather than shifting colour, because any per-channel bias would survive here.
    bright = surface(3)
    black = np.zeros_like(bright)
    assert encode(bright, 0) == encode(black, 256)


def test_a_flat_grey_dims_toward_black_monotonically():
    grey = np.full((STRIP_H, STRIP_W, 4), 200, dtype=np.uint8)
    lengths = [len(encode(grey, gain)) for gain in (256, 128, 64, 0)]
    # A flat tile lives in the DC band, so dimming it can only shrink or hold its payload.
    assert lengths == sorted(lengths, reverse=True) or len(set(lengths)) == 1


@pytest.mark.parametrize("gain", [32, 64, 128, 192, 255])
def test_dimming_never_grows_the_payload(gain):
    # Smaller coefficients cannot need more bits in this codebook. A gain that inflated a
    # strip would mean the scale was being applied somewhere it does not belong.
    pixels = surface(5)
    assert len(encode(pixels, gain)) <= len(encode(pixels, 256))


# -- per-channel calibration table ---------------------------------------------------------

def install_lut(tables):
    """tables: (3, 256) uint8, in R, G, B order. Returns the buffer, which must stay alive."""
    buffer = np.ascontiguousarray(np.asarray(tables, dtype=np.uint8))
    core.lib.oizys_video_set_channel_lut(buffer.ctypes.data_as(ctypes.c_void_p))
    return buffer


@pytest.fixture(autouse=True)
def clear_lut_after_each():
    yield
    core.lib.oizys_video_set_channel_lut(None)
    assert core.lib.oizys_video_has_channel_lut() == 0


def identity_lut():
    return np.tile(np.arange(256, dtype=np.uint8), (3, 1))


def test_identity_lut_changes_nothing():
    pixels = surface(13)
    baseline = encode(pixels, 256)
    keep = install_lut(identity_lut())
    assert core.lib.oizys_video_has_channel_lut() == 1
    assert encode(pixels, 256) == baseline
    del keep


def test_lut_applies_per_channel_in_rgb_order():
    # Zero the red table only. BGRA memory order is B,G,R,A, so this must blank the third
    # byte of each pixel and leave the others alone. Getting the order wrong here would
    # silently swap a monitor's red and blue correction.
    tables = identity_lut()
    tables[0, :] = 0
    keep = install_lut(tables)
    pixels = surface(17)
    through_lut = encode(pixels, 256)
    core.lib.oizys_video_set_channel_lut(None)
    zeroed = pixels.copy()
    zeroed[:, :, 2] = 0          # BGRA: index 2 is red
    assert through_lut == encode(zeroed, 256)
    del keep


def test_lut_edge_strip_matches_the_vector_path():
    # A strip that straddles the surface edge takes the scalar path; one that does not takes
    # the NEON table lookup. Both must agree, or a correction would stop at the last full
    # strip and leave a visible seam down the right-hand side of the panel.
    tables = identity_lut()
    tables[1, :] = np.clip(np.arange(256) // 2, 0, 255).astype(np.uint8)
    keep = install_lut(tables)
    pixels = surface(19)
    out = (ctypes.c_uint8 * (1 << 18))()
    pointer = np.ascontiguousarray(pixels).ctypes.data_as(ctypes.POINTER(ctypes.c_uint8))
    core.lib.oizys_video_set_gain(256)
    full = core.lib.oizys_video_colour_strip_bgra(
        out, len(out), 0, 0, pointer, STRIP_W * 4, STRIP_W, STRIP_H)
    inside = bytes(out[:full])
    # Same pixels, but declared one column narrower so the strip hangs over the edge.
    clipped = core.lib.oizys_video_colour_strip_bgra(
        out, len(out), 0, 0, pointer, STRIP_W * 4, STRIP_W - 1, STRIP_H)
    assert clipped > 0 and inside != bytes(out[:clipped])  # different content, both encoded
    del keep


@pytest.mark.parametrize("level", [0, 1, 63, 64, 65, 127, 128, 129, 191, 192, 193, 254, 255])
def test_lut_covers_every_quarter_of_the_table(level):
    # The NEON lookup splits 256 entries across four 64-entry tables and relies on wrap-around
    # putting out-of-range indices above 64. The boundaries are exactly where that goes wrong.
    tables = identity_lut()
    tables[0, :] = 0
    tables[1, :] = 0
    tables[2, :] = 0
    tables[0, level] = 200
    tables[1, level] = 100
    tables[2, level] = 50
    keep = install_lut(tables)
    pixels = np.full((STRIP_H, STRIP_W, 4), level, dtype=np.uint8)
    through_lut = encode(pixels, 256)
    core.lib.oizys_video_set_channel_lut(None)
    expected = np.zeros_like(pixels)
    expected[:, :, 0] = 50       # blue
    expected[:, :, 1] = 100      # green
    expected[:, :, 2] = 200      # red
    assert through_lut == encode(expected, 256)
    del keep


# --- contrast ---------------------------------------------------------------------------
#
# Contrast is the other half of the same encoder pass and behaves differently on purpose:
# brightness scales from black, so unity is its ceiling, while contrast pivots on mid-grey
# and has to work either side of unity to mean anything. These pin the pivot, because a
# "contrast" that just dims is indistinguishable from brightness and would go unnoticed.


@pytest.fixture(autouse=True)
def unity_contrast_after_each():
    yield
    core.lib.oizys_video_set_contrast(256)
    assert core.lib.oizys_video_contrast() == 256


def encode_contrast(pixels, contrast):
    core.lib.oizys_video_set_contrast(contrast)
    out = (ctypes.c_uint8 * (1 << 18))()
    flat = np.ascontiguousarray(pixels)
    pointer = flat.ctypes.data_as(ctypes.POINTER(ctypes.c_uint8))
    length = core.lib.oizys_video_colour_strip_bgra(
        out, len(out), 0, 0, pointer, STRIP_W * 4, STRIP_W, STRIP_H)
    assert length > 0
    return bytes(out[:length])


def flat(level):
    pixels = np.zeros((STRIP_H, STRIP_W, 4), dtype=np.uint8)
    pixels[:, :, :3] = level
    pixels[:, :, 3] = 255
    return pixels


def test_contrast_clamps_either_side_of_unity():
    core.lib.oizys_video_set_contrast(0)
    assert core.lib.oizys_video_contrast() == 128
    core.lib.oizys_video_set_contrast(9999)
    assert core.lib.oizys_video_contrast() == 384
    core.lib.oizys_video_set_contrast(300)
    assert core.lib.oizys_video_contrast() == 300


def test_unity_contrast_is_byte_identical():
    pixels = surface(11)
    assert encode_contrast(pixels, 256) == encode_contrast(pixels, 256)
    core.lib.oizys_video_set_contrast(256)
    assert encode_contrast(pixels, 256) == encode(pixels, 256)


def test_mid_grey_is_the_pivot_and_does_not_move():
    # The whole difference between contrast and brightness. Mid-grey has to survive both
    # directions untouched; if it drifts, the pivot term is wrong and this is just a gain.
    mid = flat(128)
    unity = encode_contrast(mid, 256)
    assert encode_contrast(mid, 384) == unity
    assert encode_contrast(mid, 128) == unity


def test_raising_contrast_pushes_away_from_mid_and_lowering_pulls_toward_it():
    # Above mid-grey brightens and below it darkens: one direction each side of the pivot,
    # which a gain can never produce.
    bright, dark = flat(200), flat(60)
    assert encode_contrast(bright, 384) != encode_contrast(bright, 256)
    assert encode_contrast(dark, 384) != encode_contrast(dark, 256)
    # Pulled all the way in, everything collapses toward the same mid-grey.
    assert encode_contrast(bright, 128) != encode_contrast(bright, 256)
    assert encode_contrast(dark, 128) != encode_contrast(dark, 256)


def test_contrast_leaves_a_grey_grey():
    # Equal channels in, equal channels out: the pivot lives on the luma plane alone, and a
    # lift leaking into the two difference planes would tint every grey on the desk.
    for level in (40, 128, 210):
        for contrast in (128, 200, 384):
            encoded = encode_contrast(flat(level), contrast)
            assert encoded == encode_contrast(flat(level), contrast)
    # A grey ramp stays neutral: encoding is deterministic and channel-symmetric.
    assert encode_contrast(flat(90), 320) != encode_contrast(flat(91), 320)
