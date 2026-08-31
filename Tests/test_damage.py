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

from Support import oizyscore as core

WIDTH, HEIGHT = 640, 256
STRIDE = WIDTH * 4
COLS = WIDTH // core.STRIP_W
ROWS = HEIGHT // core.STRIP_H


class Ledger:
    """A thin wrapper so the state machine reads as intent rather than ctypes."""

    def __init__(self, width=WIDTH, height=HEIGHT):
        self.map = core.DamageMap()
        core.lib.oizys_damage_init(ctypes.byref(self.map), width, height)
        self.strips = (core.Strip * core.MAX_STRIPS)()
        self.presentations = ctypes.c_int(0)

    def plan(self, surface: bytes):
        count = core.lib.oizys_damage_plan(
            ctypes.byref(self.map), core.as_u8(surface), STRIDE, self.strips,
            core.MAX_STRIPS, ctypes.byref(self.presentations))
        return count, [self.strips[i] for i in range(count)]

    def plan_dirty(self, surface: bytes, rects):
        array = (core.DirtyRect * len(rects))(*[core.DirtyRect(*r) for r in rects])
        count = core.lib.oizys_damage_plan_dirty(
            ctypes.byref(self.map), core.as_u8(surface), STRIDE,
            array, len(rects), self.strips, core.MAX_STRIPS,
            ctypes.byref(self.presentations))
        return count, [self.strips[i] for i in range(count)]

    def owed(self):
        count = core.lib.oizys_damage_owed(ctypes.byref(self.map), self.strips, core.MAX_STRIPS)
        return count, [self.strips[i] for i in range(count)]

    def presented(self):
        core.lib.oizys_damage_presented(ctypes.byref(self.map))


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


# ---------------------------------------------------------------------------
# The dirty-rectangle fast path. Fingerprinting the whole surface every frame is
# what made this driver cost more CPU than the vendor's; these check that reading
# less does not mean seeing less.
# ---------------------------------------------------------------------------


def _settled(ledger, surface):
    """Drive the ledger past its keyframe so the fast path is actually reachable."""
    ledger.plan(surface)
    for _ in range(core.DAMAGE_REPEATS + 1):
        ledger.presented()
        ledger.plan(surface)
    ledger.presented()


@given(st.integers(0, WIDTH - 1), st.integers(0, HEIGHT - 1))
@settings(max_examples=40, deadline=None)
def test_an_honest_rect_plans_the_same_strips_as_a_full_pass(x, y):
    """Given the rectangle that really changed, the fast path must charge exactly what
    reading every pixel would have charged."""
    surface = bytearray(STRIDE * HEIGHT)
    full, fast = Ledger(), Ledger()
    _settled(full, bytes(surface))
    _settled(fast, bytes(surface))

    surface[y * STRIDE + x * 4] ^= 0xFF
    want, want_strips = full.plan(bytes(surface))
    got, got_strips = fast.plan_dirty(bytes(surface), [(x, y, 1, 1)])
    assert got == want
    assert {(s.col, s.row) for s in got_strips} == {(s.col, s.row) for s in want_strips}


def test_a_rect_off_the_surface_is_not_trusted():
    """A rect the compositor reports outside the surface impeaches the whole list, and the
    frame falls back to reading everything rather than to reading nothing."""
    surface = bytearray(STRIDE * HEIGHT)
    ledger = Ledger()
    _settled(ledger, bytes(surface))
    surface[0] ^= 0xFF
    count, _ = ledger.plan_dirty(bytes(surface), [(WIDTH, 0, 8, 8)])
    assert count > 0, "an out-of-range rect silently suppressed a real change"


def test_a_missed_rect_is_repaired_by_the_verification_sweep():
    """The compositor's rectangle list is a hint. A change it fails to report must still
    reach the wire within OIZYS_DAMAGE_SWEEP frames, not linger forever."""
    surface = bytearray(STRIDE * HEIGHT)
    ledger = Ledger()
    _settled(ledger, bytes(surface))

    # Change a strip, then lie about where it happened.
    target_row = ROWS - 1
    surface[target_row * core.STRIP_H * STRIDE] ^= 0xFF
    elsewhere = [(0, 0, 1, 1)]
    for frame in range(core.DAMAGE_SWEEP):
        count, strips = ledger.plan_dirty(bytes(surface), elsewhere)
        if any(s.row == target_row and s.col == 0 for s in strips):
            return
        ledger.presented()
    pytest.fail(f"an unreported change never reached the wire in {core.DAMAGE_SWEEP} frames")
