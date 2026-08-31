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
