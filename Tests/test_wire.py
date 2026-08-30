"""An independent reader for the strip wire grammar.

Reads a strip by the grammar written down from the oracle rather than by calling the
encoder back, so an encoder that is self-consistently wrong still fails here. This is what
caught the luma ceiling: chroma's cap on a luma coefficient emits a terminating bit the
dock reads as an offset, and everything after it in the half-strip decodes off by one.
"""
import pytest
from hypothesis import HealthCheck, given, settings

from Support import mviewcore as core
from conftest import bgra_surface

# Each region rounds up to a whole byte, then to an even byte count.
MAX_REGION_SLACK = 15


class BitReader:
    def __init__(self, data: bytes):
        self.data = data
        self.bit = 0
        self.limit = len(data) * 8
        self.overran = False

    def read(self) -> int:
        if self.bit >= self.limit:
            self.overran = True
            return 0
        value = (self.data[self.bit >> 3] >> (self.bit & 7)) & 1
        self.bit += 1
        return value

    def symbol(self, cap: int) -> int:
        category = 0
        while category < cap and self.read():
            category += 1
        if category == 0:
            return 0
        offset = 0
        for _ in range(category - 1):
            offset = (offset << 1) | self.read()
        magnitude = offset + (1 << (category - 1))
        return magnitude if self.read() else -magnitude

    @property
    def slack(self) -> int:
        return self.limit - self.bit


def scan_at(position: int) -> int:
    return (position + 1) // 2 if position & 1 else 63 - position // 2


def decode(strip: bytes):
    """Walk a whole strip. Returns (last table, per-region slack)."""
    assert len(strip) >= 18, "strip shorter than its header"
    assert strip[0] == 0x01 and strip[1] == 0x28, "wrong strip magic"
    main_end = int.from_bytes(strip[10:12], "little")
    second_row = int.from_bytes(strip[12:14], "little")
    assert 18 <= main_end <= second_row <= len(strip), "region offsets out of order"

    main = BitReader(strip[16:main_end - 2])
    last = [[0] * 3 for _ in range(16)]
    for block in range(16):
        for plane in range(3):
            value = main.symbol(core.CAP_SYNC)
            recovered = value + 32 if plane == 2 else (value + 64 if value < 0 else value)
            assert 0 <= recovered <= 63, f"last-significant scan {recovered} out of range"
            last[block][plane] = recovered
    for _ in range(48):
        main.symbol(core.CAP_DC)
    assert not main.overran, "reader ran past the main region"

    slack = [main.slack]
    for half in range(2):
        start = main_end if half == 0 else second_row
        end = second_row if half == 0 else len(strip)
        row = BitReader(strip[start:end])
        for block in range(half * 8, half * 8 + 8):
            for plane in range(3):
                if last[block][plane] == 0:
                    continue
                cap = core.CAP_AC_LUMA if plane == 2 else core.CAP_AC
                for position in range(63):
                    row.symbol(cap)
                    if scan_at(position) == last[block][plane]:
                        break
        assert not row.overran, f"reader ran past AC region {half}"
        slack.append(row.slack)
    return last, slack


@given(bgra_surface())
@settings(max_examples=80, deadline=None,
          suppress_health_check=[HealthCheck.too_slow, HealthCheck.data_too_large])
def test_every_strip_stays_in_sync_under_the_grammar(surface):
    data, stride, width, height = surface
    strip = core.encode_strip(data, stride, width, height)
    assert strip, "encoder declined a strip that fits"
    _, slack = decode(strip)
    for index, remaining in enumerate(slack):
        assert remaining <= MAX_REGION_SLACK, (
            f"region {index} left {remaining} bits unread; the reader lost the grammar"
        )


def test_header_carries_the_strip_origin():
    stride = 256 * 4
    data = bytes([(i * 11) % 256 if i % 4 != 3 else 255 for i in range(stride * 64)])
    strip = core.encode_strip(data, stride, 256, 64, x=128, y=32)
    assert int.from_bytes(strip[2:4], "little") == 128
    assert int.from_bytes(strip[4:6], "little") == 32
