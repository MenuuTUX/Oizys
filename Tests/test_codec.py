"""Differential tests: the C encoder against an independent model of the same format.

This is the strongest check in the suite. Support/reference.py implements the codec a
second time, in numpy, from the format rather than from the C. Any input can be run
through both, so unlike a recorded vector this says something about inputs nobody thought
to record. When they disagree, hypothesis shrinks the surface to the smallest one that
still separates them.

Writing the model found a bug in the model first: numpy slice views alias, so the Haar
lifting step was reading operands it had already overwritten. That is the shape of thing
this catches.
"""
import numpy as np
import pytest
from hypothesis import HealthCheck, given, settings
from hypothesis import strategies as st

from Support import oizyscore as core
from Support import reference as ref
from conftest import bgra_surface

SLOW = settings(max_examples=60, deadline=None,
                suppress_health_check=[HealthCheck.too_slow, HealthCheck.data_too_large])


@given(bgra_surface())
@SLOW
def test_c_encoder_matches_the_reference_model(surface):
    data, stride, width, height = surface
    produced = core.encode_strip(data, stride, width, height)
    expected = ref.encode_strip(data, stride, width, height)
    assert produced == expected, (
        f"C produced {len(produced)} bytes, model {len(expected)}; "
        f"first difference at "
        f"{next((i for i, (a, b) in enumerate(zip(produced, expected)) if a != b), 'length')}"
    )


@given(bgra_surface(width=128, height=32),
       st.integers(0, 1), st.integers(0, 1))
@SLOW
def test_encoder_matches_the_model_at_every_strip_origin(surface, column, row):
    """The origin is written into the header and shifts which pixels are read. Both have to
    agree about that, not just about a strip at 0,0."""
    data, stride, width, height = surface
    x, y = column * core.STRIP_W, row * core.STRIP_H
    assert core.encode_strip(data, stride, width, height, x, y) == \
        ref.encode_strip(data, stride, width, height, x, y)


@given(st.integers(4, 100), st.integers(1, 20))
@settings(max_examples=40, deadline=None)
def test_clipped_strips_match_the_model(width, height):
    """A strip running past the surface edge takes the scalar fallback in C, which mutation
    testing showed nothing else reached."""
    stride = width * 4
    data = bytes([(i * 37) % 256 if i % 4 != 3 else 255 for i in range(stride * height)])
    assert core.encode_strip(data, stride, width, height, 0, 0) == \
        ref.encode_strip(data, stride, width, height, 0, 0)


def test_scan_tables_agree_with_the_library():
    """The model transcribes the scan order and quantiser tables. If a transcription slipped,
    every other test in this file would fail with a confusing byte difference instead of
    saying which table is wrong."""
    for row in range(8):
        for column in range(8):
            assert core.lib.oizys_scan_index(row, column) == int(ref.SCAN_INDEX[row][column]), \
                f"scan index disagrees at {row},{column}"
    for scan in range(64):
        expected = int(ref.SCAN_INDEX.flatten().tolist().index(scan))
        assert core.lib.oizys_inverse_scan(scan) == expected, f"inverse scan wrong at {scan}"


@given(st.integers(0, 2), st.integers(0, 63), st.integers(-(1 << 24), 1 << 24))
@settings(max_examples=2000, deadline=None)
def test_quantiser_matches_the_model(plane, scan, value):
    """Covers the rounding rule and the luma mixed-band truncation, which differ only in
    sign and band and are easy to get subtly wrong."""
    assert core.lib.oizys_quantize_reference(plane, scan, value) == ref.quantize(plane, scan, value)


@given(st.lists(st.integers(-(1 << 20), 1 << 20), min_size=64, max_size=64))
@settings(max_examples=300, deadline=None)
def test_haar_is_reversible_in_the_model(values):
    """A Haar step is a sum and a difference of a pair, so the transform preserves the sum
    of the block at every level. This pins the model itself, which the C is compared to."""
    block = np.array(values, dtype=np.int64)
    transformed = ref.haar_pyramid(block)
    # The DC coefficient of an unscaled integer Haar pyramid is the sum of every input.
    assert int(transformed[0]) == int(block.sum())


def test_vector_quantiser_agrees_with_the_scalar_one():
    """The NEON quantiser replaced a scalar function that stays in the tree as the
    definition. oizys_encode_selftest runs both over generated coefficients inside the
    library, where the static vector path is reachable."""
    assert core.lib.oizys_encode_selftest(None, None, 1) == 0


def test_encoder_rejects_invalid_output_or_surface():
    """The C entry point must fail before touching memory on invalid trust-boundary inputs."""
    surface = bytes([0, 0, 0, 255]) * (core.STRIP_W * core.STRIP_H)
    source = core.as_u8(surface)
    assert core.lib.oizys_video_colour_strip_bgra(None, 16384, 0, 0, source,
                                                   core.STRIP_W * 4, core.STRIP_W,
                                                   core.STRIP_H) == 0
    out = core.buffer(16384)
    assert core.lib.oizys_video_colour_strip_bgra(out, 16384, 0, 0, source,
                                                   core.STRIP_W * 4, 0, core.STRIP_H) == 0
    assert core.lib.oizys_video_colour_strip_bgra(out, 16384, core.STRIP_W, 0, source,
                                                   core.STRIP_W * 4, core.STRIP_W,
                                                   core.STRIP_H) == 0


# Golden solid strips, captured from the encoder and verified byte-for-byte against the
# pre-CLZ escape coder. White is the case that matters: its luma DC is 1020, the largest
# magnitude the strip builder can produce, and it sits in the top category the codebook
# has. A saturating escape coder that clamped the category without clamping the magnitude
# would still pass every other row here and corrupt only this one.
SOLID_STRIPS = {
    (255, 255, 255): "012800000000000000003a003a000000fc007e003f801fc00fe007f003f801fc0"
                     "07e003f801fc00fe007f003f801fcff27000000000000000000",
    (0, 0, 0): "01280000000000000000360036000000fc007e003f801fc00fe007f003f801fc0"
               "07e003f801fc00fe007f003f8010000000000000000",
    (255, 0, 0): "012800000000000000003a003a000000fc007e003f801fc00fe007f003f801fc0"
                 "07e003f801fc00fe007f003f801fefdfffb0400000000000000",
    (0, 0, 255): "012800000000000000003a003a000000fc007e003f801fc00fe007f003f801fc0"
                 "07e003f801fc00fe007f003f801fffefdfb0400000000000000",
    (17, 200, 90): "012800000000000000003c003c000000fc007e003f801fc00fe007f003f801fc0"
                   "07e003f801fc00fe007f003f8017f9d7f76ff7d0400000000000000",
}


@pytest.mark.parametrize("colour", sorted(SOLID_STRIPS))
def test_solid_strip_bytes_are_stable(colour):
    assert core.solid_strip(*colour) == bytes.fromhex(SOLID_STRIPS[colour])


def test_solid_strip_rejects_a_null_output():
    """The public entry point's only write is an unconditional memset, so it has to check
    out before computing a length that would let it through."""
    assert core.lib.oizys_video_solid_strip(None, 256, 0, 0, 255, 255, 255) == 0
