"""Shared fixtures and strategies.

Adds Tests/ to the path so `Support` imports without an installed package, and defines the
surface strategies the codec suites share.
"""
import pathlib
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))

import pytest
from hypothesis import strategies as st

from Support import mviewcore as core

STRIP_W = core.STRIP_W
STRIP_H = core.STRIP_H


@st.composite
def bgra_surface(draw, width=STRIP_W, height=STRIP_H, style=None):
    """A BGRA surface.

    Styles are drawn rather than fixed because the codec's paths are content dependent: a
    flat tile never leaves the DC band, noise saturates the escape codes, and hard edges
    are what first drove a luma coefficient past the codebook. Generating only one of them
    exercises a third of the encoder.
    """
    style = style or draw(st.sampled_from(["flat", "noise", "edges", "gradient", "sparse"]))
    stride = width * 4
    data = bytearray(stride * height)

    if style == "flat":
        colour = draw(st.tuples(*[st.integers(0, 255)] * 3))
        for i in range(width * height):
            data[i * 4:i * 4 + 4] = bytes([colour[0], colour[1], colour[2], 255])
    elif style == "noise":
        raw = draw(st.binary(min_size=width * height * 3, max_size=width * height * 3))
        for i in range(width * height):
            data[i * 4:i * 4 + 4] = bytes([raw[i * 3], raw[i * 3 + 1], raw[i * 3 + 2], 255])
    elif style == "edges":
        period = draw(st.integers(1, 8))
        dark = draw(st.integers(0, 60))
        light = draw(st.integers(195, 255))
        for y in range(height):
            for x in range(width):
                v = dark if ((x // period + y // period) % 2) else light
                data[(y * width + x) * 4:(y * width + x) * 4 + 4] = bytes([v, v, v, 255])
    elif style == "gradient":
        for y in range(height):
            for x in range(width):
                o = (y * width + x) * 4
                data[o:o + 4] = bytes([(x * 4) % 256, (y * 16) % 256, (x + y) % 256, 255])
    else:  # sparse: mostly flat with a few outliers, the common desktop case
        base = draw(st.integers(0, 255))
        for i in range(width * height):
            data[i * 4:i * 4 + 4] = bytes([base, base, base, 255])
        for _ in range(draw(st.integers(0, 12))):
            i = draw(st.integers(0, width * height - 1))
            v = draw(st.integers(0, 255))
            data[i * 4:i * 4 + 3] = bytes([v, v, v])
    return bytes(data), stride, width, height


@pytest.fixture(scope="session")
def library_path():
    return core.LIBRARY_PATH
