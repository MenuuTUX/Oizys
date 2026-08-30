"""An independent model of the Ridge colour-strip codec.

Golden vectors lock in what the encoder currently does. They cannot tell a fixed bug from
a new one, and they say nothing about inputs nobody recorded. This is the other kind of
check: a second implementation, written from the format rather than from the C, that any
input can be run through. When the two disagree, one of them is wrong and the input that
separated them is in hand.

Written for clarity, not speed. It is a specification you can execute.
"""
from __future__ import annotations

import numpy as np

STRIP_W = 64
STRIP_H = 16
CAP_SYNC = 7
CAP_DC = 10
CAP_AC = 10
CAP_AC_LUMA = 9

# Position within an 8x8 block to its coefficient index. Measured from the oracle; the
# suite checks this against the library's own table so a transcription slip shows up as a
# table mismatch rather than a puzzling encode difference.
SCAN_INDEX = np.array([
    [0, 63, 2, 61, 8, 10, 55, 53],
    [1, 62, 3, 60, 12, 14, 51, 49],
    [4, 59, 6, 57, 9, 11, 54, 52],
    [5, 58, 7, 56, 13, 15, 50, 48],
    [16, 18, 47, 45, 24, 26, 39, 37],
    [20, 22, 43, 41, 28, 30, 35, 33],
    [17, 19, 46, 44, 25, 27, 38, 36],
    [21, 23, 42, 40, 29, 31, 34, 32],
], dtype=np.int64)

# Row 0 covers the two colour-difference planes, row 1 the luma-like plane.
QUANT_SHIFT = np.array([
    [12, 10, 10, 10, 10, 10, 11, 11, 11, 11, 11, 11, 11, 11, 11, 11,
     11, 11, 11, 11, 11, 11, 11, 11, 12, 12, 12, 12, 12, 12, 12, 12,
     12, 12, 12, 12, 12, 12, 12, 12, 11, 11, 11, 11, 11, 11, 11, 11,
     11, 11, 11, 11, 11, 11, 11, 11, 11, 11, 10, 10, 10, 10, 11, 10],
    [10, 10, 8, 8, 8, 8, 9, 9, 7, 7, 7, 7, 7, 7, 7, 7,
     7, 7, 7, 7, 7, 7, 7, 7, 8, 8, 8, 8, 8, 8, 8, 8,
     8, 8, 8, 8, 8, 8, 8, 8, 7, 7, 7, 7, 7, 7, 7, 7,
     7, 7, 7, 7, 7, 7, 7, 7, 9, 9, 8, 8, 8, 8, 11, 10],
], dtype=np.int64)


def scan_at(position: int) -> int:
    """Coefficient index visited at a given position in the coding order."""
    return (position + 1) // 2 if position & 1 else 63 - position // 2


def mixed_band(scan: int) -> bool:
    """Scan positions 8-23 and 40-55 are the mixed horizontal/vertical detail bands."""
    return 8 <= scan <= 23 or 40 <= scan <= 55


class BitWriter:
    """Bits least-significant-first within each byte, bytes ascending."""

    def __init__(self):
        self.bits: list[int] = []

    def put(self, value: int, count: int) -> None:
        for i in range(count):
            self.bits.append((value >> i) & 1)

    def symbol(self, value: int, cap: int) -> None:
        """A unary category prefix, the magnitude's low bits most-significant first, then
        the sign. At the cap the terminating zero is omitted, because no longer category
        can follow -- which is the rule the luma ceiling bug got wrong."""
        if value == 0:
            self.put(0, 1)
            return
        magnitude = abs(value)
        category = magnitude.bit_length()
        if category > cap:
            # Saturate rather than emit a prefix longer than the codebook allows.
            category = cap
            magnitude = (1 << cap) - 1
        self.put((1 << category) - 1, category)
        if category < cap:
            self.put(0, 1)
        offset = magnitude - (1 << (category - 1))
        for bit in range(category - 1, 0, -1):
            self.put((offset >> (bit - 1)) & 1, 1)
        self.put(1 if value > 0 else 0, 1)

    def to_bytes(self) -> bytes:
        out = bytearray((len(self.bits) + 7) // 8)
        for index, bit in enumerate(self.bits):
            if bit:
                out[index >> 3] |= 1 << (index & 7)
        return bytes(out)


def to_planes(surface: bytes, stride: int, width: int, height: int,
              x: int, y: int) -> np.ndarray:
    """The three planes for one 64x16 strip, as (16 blocks, 3 planes, 64 samples).

    Samples outside the surface stay zero, which is what the C fallback does for a strip
    clipped by the right or bottom edge.
    """
    planes = np.zeros((16, 3, 64), dtype=np.int64)
    data = np.frombuffer(surface, dtype=np.uint8)
    for block in range(16):
        block_x, block_y = (block % 8) * 8, (block // 8) * 8
        for py in range(8):
            source_y = y + block_y + py
            if source_y >= height:
                continue
            for px in range(8):
                source_x = x + block_x + px
                if source_x >= width:
                    continue
                offset = source_y * stride + source_x * 4
                blue, green, red = int(data[offset]), int(data[offset + 1]), int(data[offset + 2])
                red_delta, blue_delta = red - green, blue - green
                sample = py * 8 + px
                planes[block][0][sample] = 64 * blue_delta
                planes[block][1][sample] = 64 * red_delta
                # >> on a negative value is arithmetic in both C and numpy int64.
                planes[block][2][sample] = 64 * green + 64 * ((red_delta + blue_delta) >> 2)
    return planes


def haar_pyramid(values: np.ndarray) -> np.ndarray:
    """Three levels of unscaled integer Haar lifting over an 8x8 block, rows then columns."""
    grid = values.reshape(8, 8).copy()
    size = 8
    while size >= 2:
        half = size // 2
        # The pairs must be copied out first. A numpy slice is a view, so writing the sums
        # into the left half would change the operands the differences are computed from.
        even = grid[:size, 0:size:2].copy()
        odd = grid[:size, 1:size:2].copy()
        grid[:size, :half] = even + odd
        grid[:size, half:size] = even - odd

        even = grid[0:size:2, :size].copy()
        odd = grid[1:size:2, :size].copy()
        grid[:half, :size] = even + odd
        grid[half:size, :size] = even - odd
        size = half
    return grid.reshape(64)


def quantize(plane: int, scan: int, value: int) -> int:
    shift = int(QUANT_SHIFT[1 if plane == 2 else 0][scan])
    # Ridge rounds, except that the luma plane's mixed detail bands truncate positives.
    bias = 0 if (plane == 2 and mixed_band(scan) and value >= 0) else (1 << shift) >> 1
    return (int(value) + bias) >> shift


def encode_strip(surface: bytes, stride: int, width: int, height: int,
                 x: int = 0, y: int = 0) -> bytes:
    """One colour strip, in the layout the dock expects."""
    planes = to_planes(surface, stride, width, height, x, y)
    coefficients = np.zeros((16, 3, 64), dtype=np.int64)
    last = np.zeros((16, 3), dtype=np.int64)

    for block in range(16):
        for plane in range(3):
            transformed = haar_pyramid(planes[block][plane])
            for row in range(8):
                for column in range(8):
                    scan = int(SCAN_INDEX[row][column])
                    coefficients[block][plane][scan] = quantize(
                        plane, scan, int(transformed[row * 8 + column]))
            for position in range(63):
                scan = scan_at(position)
                if coefficients[block][plane][scan] != 0:
                    last[block][plane] = scan

    main = BitWriter()
    for block in range(16):
        for plane in range(3):
            value = int(last[block][plane])
            if plane == 2:
                value -= 32
            elif value >= 32:
                value -= 64
            main.symbol(value, CAP_SYNC)

    previous = [0, 0, 0]
    for block in range(16):
        for plane in range(3):
            dc = int(coefficients[block][plane][0])
            main.symbol(dc - previous[plane], CAP_DC)
            previous[plane] = dc

    rows = [BitWriter(), BitWriter()]
    for block in range(16):
        writer = rows[block // 8]
        for plane in range(3):
            if last[block][plane] == 0:
                continue
            cap = CAP_AC_LUMA if plane == 2 else CAP_AC
            for position in range(63):
                scan = scan_at(position)
                writer.symbol(int(coefficients[block][plane][scan]), cap)
                if scan == last[block][plane]:
                    break

    main_bytes = main.to_bytes()
    row_bytes = [rows[0].to_bytes(), rows[1].to_bytes()]
    if not main_bytes:
        return b""

    def pad(n: int) -> int:
        return (n + 1) & ~1

    main_end = 16 + pad(len(main_bytes)) + 2
    second_row = main_end + pad(len(row_bytes[0]))
    length = second_row + pad(len(row_bytes[1]))

    out = bytearray(length)
    out[0], out[1] = 0x01, 0x28
    out[2:4] = int(x).to_bytes(2, "little")
    out[4:6] = int(y).to_bytes(2, "little")
    out[10:12] = main_end.to_bytes(2, "little")
    out[12:14] = second_row.to_bytes(2, "little")
    out[16:16 + len(main_bytes)] = main_bytes
    out[main_end:main_end + len(row_bytes[0])] = row_bytes[0]
    out[second_row:second_row + len(row_bytes[1])] = row_bytes[1]
    return bytes(out)
