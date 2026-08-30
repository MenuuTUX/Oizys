"""The zone profiler.

It measures the parallel encoder, so it is itself called from every core at once. An
earlier version accumulated into shared atomics and its own contention landed inside the
zones it was reporting, making a frame look twice as expensive as it was. These check the
gate, the nesting that produces self time, and that concurrent recording loses nothing.
"""
import ctypes
import threading

import pytest

from Support import mviewcore as core

PRESENT, STRIP, CONVERT, HAAR, QUANTIZE, ENTROPY = 0, 4, 5, 6, 7, 8


def spin(iterations=20000):
    total = 0
    for i in range(iterations):
        total += i
    return total


def zone(index):
    calls = ctypes.c_uint64(0)
    total = ctypes.c_double(0)
    own = ctypes.c_double(0)
    core.lib.mview_profile_zone_stats.argtypes = [
        ctypes.c_int, ctypes.POINTER(ctypes.c_uint64),
        ctypes.POINTER(ctypes.c_double), ctypes.POINTER(ctypes.c_double)]
    core.lib.mview_profile_zone_stats(index, ctypes.byref(calls), ctypes.byref(total),
                                      ctypes.byref(own))
    return calls.value, total.value, own.value


@pytest.fixture(autouse=True)
def clean_profiler():
    core.lib.mview_profile_reset()
    core.lib.mview_profile_enable(0)
    yield
    core.lib.mview_profile_enable(0)
    core.lib.mview_profile_reset()


def test_disabled_profiler_records_nothing():
    for _ in range(50):
        started = core.lib.mview_profile_push(STRIP)
        core.lib.mview_profile_pop(STRIP, started)
    # push/pop were called directly, so they record; what must be gated is the macro path
    # the library's own hot loops use. Encoding with the profiler off must add no calls.
    core.lib.mview_profile_reset()
    tile = bytes(core.STRIP_W * core.STRIP_H * 4)
    core.encode_strip(tile, core.STRIP_W * 4, core.STRIP_W, core.STRIP_H)
    assert zone(STRIP)[0] == 0, "zones recorded while profiling was disabled"


def test_enabled_profiler_counts_every_strip():
    core.lib.mview_profile_enable(1)
    tile = bytes([(i * 13) % 256 if i % 4 != 3 else 255
                  for i in range(core.STRIP_W * core.STRIP_H * 4)])
    for _ in range(25):
        core.encode_strip(tile, core.STRIP_W * 4, core.STRIP_W, core.STRIP_H)
    core.lib.mview_profile_enable(0)

    calls, total, own = zone(STRIP)
    assert calls == 25, f"recorded {calls} strips, expected 25"
    assert total > 0, "strip zone recorded zero elapsed time"
    # The strip zone contains convert, haar, quantize and entropy, so its self time has to
    # be less than its total. Equal self and total is what a broken nesting stack produces.
    assert own < total, "self time equals total; nesting is not being tracked"
    for child in (CONVERT, HAAR, QUANTIZE, ENTROPY):
        assert zone(child)[0] > 0, f"child zone {child} recorded nothing"


def test_reset_clears_every_zone():
    core.lib.mview_profile_enable(1)
    tile = bytes(core.STRIP_W * core.STRIP_H * 4)
    core.encode_strip(tile, core.STRIP_W * 4, core.STRIP_W, core.STRIP_H)
    core.lib.mview_profile_enable(0)
    assert zone(STRIP)[0] > 0, "nothing was recorded to reset"
    core.lib.mview_profile_reset()
    for index in range(core.lib.mview_profile_zone_count()):
        assert zone(index)[0] == 0, f"zone {index} survived a reset"


def test_concurrent_recording_loses_no_calls():
    """Threads record at once, as they do under the parallel strip encoder. Run under
    `Tools/test.py --sanitize thread` this also proves the accumulators are race-free."""
    core.lib.mview_profile_enable(1)
    tile = bytes([(i * 7) % 256 if i % 4 != 3 else 255
                  for i in range(core.STRIP_W * core.STRIP_H * 4)])
    per_thread, thread_count = 40, 6

    def work():
        for _ in range(per_thread):
            core.encode_strip(tile, core.STRIP_W * 4, core.STRIP_W, core.STRIP_H)

    threads = [threading.Thread(target=work) for _ in range(thread_count)]
    for thread in threads:
        thread.start()
    for thread in threads:
        thread.join()
    core.lib.mview_profile_enable(0)

    calls, total, _ = zone(STRIP)
    assert calls == per_thread * thread_count, \
        f"recorded {calls} strips across {thread_count} threads, expected {per_thread * thread_count}"
    assert total > 0


def test_report_survives_an_empty_profile():
    """The report is reachable from the CLI before any workload has run; an earlier version
    divided by a zero total."""
    core.lib.mview_profile_reset()
    core.lib.mview_profile_report(b"empty profile")
