"""The damage ledger, driven as a state machine.

The ledger carries per-strip debt across frames, so its bugs are sequence bugs: a strip
that stops being owed one frame too early leaves a stale tile on one of the dock's buffers
and nothing repairs it. Single-call tests cannot reach that. Hypothesis drives arbitrary
sequences of paint, plan and present, checks the invariants after every step, and shrinks
any failure to the shortest sequence that still breaks it.
"""
import ctypes

import pytest
from hypothesis import HealthCheck, given, settings
from hypothesis import strategies as st
from hypothesis.stateful import RuleBasedStateMachine, invariant, precondition, rule

from Support import mviewcore as core

WIDTH, HEIGHT = 640, 256
STRIDE = WIDTH * 4
COLS = WIDTH // core.STRIP_W
ROWS = HEIGHT // core.STRIP_H


class Ledger:
    """A thin wrapper so the state machine reads as intent rather than ctypes."""

    def __init__(self, width=WIDTH, height=HEIGHT):
        self.map = core.DamageMap()
        core.lib.mview_damage_init(ctypes.byref(self.map), width, height)
        self.strips = (core.Strip * core.MAX_STRIPS)()
        self.presentations = ctypes.c_int(0)

    def plan(self, surface: bytes):
        count = core.lib.mview_damage_plan(
            ctypes.byref(self.map), core.as_u8(surface), STRIDE, self.strips,
            core.MAX_STRIPS, ctypes.byref(self.presentations))
        return count, [self.strips[i] for i in range(count)]

    def owed(self):
        count = core.lib.mview_damage_owed(ctypes.byref(self.map), self.strips, core.MAX_STRIPS)
        return count, [self.strips[i] for i in range(count)]

    def presented(self):
        core.lib.mview_damage_presented(ctypes.byref(self.map))


class DamageLedgerMachine(RuleBasedStateMachine):
    def __init__(self):
        super().__init__()
        self.ledger = Ledger()
        self.surface = bytearray(STRIDE * HEIGHT)
        self.dirty: set[tuple[int, int]] = set()
        self.keyframe_done = False
        self.last_plan = 0

    @rule(x=st.integers(0, WIDTH - 1), y=st.integers(0, HEIGHT - 1),
          value=st.integers(0, 255))
    def paint(self, x, y, value):
        offset = y * STRIDE + x * 4
        if self.surface[offset] != value:
            self.surface[offset] = value
            self.dirty.add((x // core.STRIP_W, y // core.STRIP_H))

    @rule()
    def plan(self):
        count, strips = self.ledger.plan(bytes(self.surface))
        self.last_plan = count
        planned = {(s.col, s.row) for s in strips}
        for strip in strips:
            assert strip.col < COLS and strip.row < ROWS, f"planned out-of-range {strip}"
        if not self.keyframe_done:
            assert count == COLS * ROWS, f"first plan owed {count}, expected a full keyframe"
            assert self.ledger.presentations.value == core.DAMAGE_REPEATS
        else:
            # Every strip whose pixels changed has to be in the plan. The ledger charges
            # whole macro tiles, so the plan may be larger, never smaller.
            missing = self.dirty - planned
            assert not missing, f"changed strips absent from the plan: {sorted(missing)}"
        self.dirty.clear()

    @rule()
    def present(self):
        self.ledger.presented()
        self.keyframe_done = True

    @invariant()
    def debt_never_exceeds_the_repeat_count(self):
        for index in range(COLS * ROWS):
            assert self.ledger.map.debt[index] <= core.DAMAGE_REPEATS, (
                f"strip {index} carries debt {self.ledger.map.debt[index]}, "
                f"more than {core.DAMAGE_REPEATS}"
            )

    @invariant()
    @precondition(lambda self: self.keyframe_done)
    def owed_strips_are_in_range(self):
        count, strips = self.ledger.owed()
        assert count <= COLS * ROWS
        for strip in strips:
            assert strip.col < COLS and strip.row < ROWS


TestDamageLedger = DamageLedgerMachine.TestCase
TestDamageLedger.settings = settings(
    max_examples=40, stateful_step_count=30, deadline=None,
    suppress_health_check=[HealthCheck.too_slow])


def test_a_still_surface_eventually_owes_nothing():
    """The steady state the driver spends most of its time in: nothing moved, so nothing
    should reach the wire."""
    ledger = Ledger()
    surface = bytes((i * 31) % 256 for i in range(STRIDE * HEIGHT))
    ledger.plan(surface)
    ledger.presented()
    for _ in range(core.DAMAGE_REPEATS + 1):
        ledger.plan(surface)
        ledger.presented()
    count, _ = ledger.plan(surface)
    assert count == 0, f"an unchanged surface still owed {count} strips"


@given(st.integers(0, WIDTH - 1), st.integers(0, HEIGHT - 1))
@settings(max_examples=40, deadline=None)
def test_one_pixel_charges_exactly_its_macro_tile(x, y):
    ledger = Ledger()
    surface = bytearray(STRIDE * HEIGHT)
    ledger.plan(bytes(surface))
    for _ in range(core.DAMAGE_REPEATS + 1):
        ledger.presented()
        ledger.plan(bytes(surface))
    ledger.presented()

    surface[y * STRIDE + x * 4] ^= 0xFF
    count, strips = ledger.plan(bytes(surface))
    assert count <= core.MACRO_STRIPS ** 2, f"one pixel charged {count} strips"
    assert (x // core.STRIP_W, y // core.STRIP_H) in {(s.col, s.row) for s in strips}
