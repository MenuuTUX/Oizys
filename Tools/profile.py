#!/usr/bin/env python3
"""Scanout profiler.

Collection stays in C, because the zones being measured are tens of nanoseconds and a
Python callback would cost more than the work. Everything above that -- driving workloads,
attributing time through the zone tree, comparing against a saved baseline -- is here,
where it is worth having more than a printf.

    python3 Tools/profile.py                     profile the default workload
    python3 Tools/profile.py --workload keyframe
    python3 Tools/profile.py --save baseline.json
    python3 Tools/profile.py --compare baseline.json
"""
from __future__ import annotations

import argparse
import ctypes
import json
import pathlib
import statistics
import sys
import time

ROOT = pathlib.Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "Tests"))

if __name__ == "__main__" and sys.argv[1:2] == ["--fixture"]:
    from fixture import main as fixture_main
    sys.exit(fixture_main(sys.argv[2:]))

from Support import oizyscore as core  # noqa: E402

WIDTH, HEIGHT = 1920, 1080
STRIDE = WIDTH * 4
COLS = WIDTH // core.STRIP_W

# Indentation in the C zone names encodes the tree. Kept there so both reports agree.
ZONES = [
    "PRESENT", "DAMAGE_PLAN", "DAMAGE_HASH", "ENCODE_STRIPS", "STRIP",
    "CONVERT", "HAAR", "QUANTIZE", "ENTROPY", "SUBMIT", "USB_WRITE", "CONTROL",
]


def zone_stats():
    """(name, calls, total_ms, self_ms, depth) for every zone that ran."""
    core.lib.oizys_profile_zone_stats.restype = None
    core.lib.oizys_profile_zone_stats.argtypes = [
        ctypes.c_int, ctypes.POINTER(ctypes.c_uint64),
        ctypes.POINTER(ctypes.c_double), ctypes.POINTER(ctypes.c_double)]
    core.lib.oizys_profile_zone_name.restype = ctypes.c_char_p
    core.lib.oizys_profile_zone_name.argtypes = [ctypes.c_int]
    core.lib.oizys_profile_zone_count.restype = ctypes.c_int

    rows = []
    for index in range(core.lib.oizys_profile_zone_count()):
        calls = ctypes.c_uint64(0)
        total = ctypes.c_double(0)
        own = ctypes.c_double(0)
        core.lib.oizys_profile_zone_stats(index, ctypes.byref(calls), ctypes.byref(total),
                                          ctypes.byref(own))
        if calls.value == 0:
            continue
        label = core.lib.oizys_profile_zone_name(index).decode()
        depth = (len(label) - len(label.lstrip())) // 2
        rows.append({"zone": label.strip(), "depth": depth, "calls": calls.value,
                     "total_ms": total.value, "self_ms": own.value})
    return rows


def paint_desktop():
    """A surface with the mix a real desktop has: flat chrome, a bright window, dense text
    rows. A flat or black surface quantises to nothing and profiles the fingerprint pass
    and little else, which is how a black frame once passed for a valid profile."""
    # A ctypes buffer, not a bytearray: the workload hands this to the library on every
    # call, and converting a bytearray to bytes each time would copy 8 MB per frame and
    # land inside the timings this exists to report.
    surface = core.buffer(STRIDE * HEIGHT)
    seed = 0x9E3779B9
    for y in range(HEIGHT):
        row = y * STRIDE
        window = 120 < y < 900
        for x in range(WIDTH):
            if y < 28:
                r = g = b = 236
            elif window and 200 < x < 1500:
                ink = ((y - 130) % 19) < 9 and ((x * 7 + y * 13) & 15) > 6
                r = g = b = 18 if ink else 246
            else:
                r, g, b = 24 + (x * 90) // WIDTH, 28 + (y * 70) // HEIGHT, 60
            seed = (seed * 1664525 + 1013904223) & 0xFFFFFFFF
            offset = row + x * 4
            surface[offset] = (b + ((seed >> 24) & 7) - 3) & 0xFF
            surface[offset + 1] = g
            surface[offset + 2] = r
            surface[offset + 3] = 255
    return surface


class Workload:
    """Drives the library the way the driver does, so the zones nest as they do live."""

    def __init__(self, frames=120):
        self.frames = frames
        self.surface = paint_desktop()
        self.pointer = ctypes.cast(self.surface, ctypes.POINTER(ctypes.c_uint8))
        self.map = core.DamageMap()
        core.lib.oizys_damage_init(ctypes.byref(self.map), WIDTH, HEIGHT)
        self.strips = (core.Strip * core.MAX_STRIPS)()
        self.presentations = ctypes.c_int(0)
        self.body = core.buffer(4096)
        self.planned = []

    def _plan(self):
        return core.lib.oizys_damage_plan(
            ctypes.byref(self.map), self.pointer, STRIDE, self.strips,
            core.MAX_STRIPS, ctypes.byref(self.presentations))

    def _encode(self, count):
        body = ctypes.cast(self.body, ctypes.POINTER(ctypes.c_uint8))
        encode = core.lib.oizys_video_colour_strip_bgra
        for i in range(count):
            encode(body, 4096, self.strips[i].x, self.strips[i].y, self.pointer, STRIDE,
                   WIDTH, HEIGHT)

    def damage(self, frame):
        """A dragged window: a block of pixels moves each frame."""
        x = (frame * 37) % (WIDTH - 200) + 8
        y = (frame * 53) % (HEIGHT - 120) + 8
        for dy in range(96):
            start = (y + dy) * STRIDE + x * 4
            ctypes.memset(ctypes.byref(self.surface, start), (frame * 7 + dy) & 0xFF, 720)

    def run(self, style="desktop"):
        wall = []
        for frame in range(self.frames):
            if frame and style != "keyframe":
                self.damage(frame)
            started = time.perf_counter()
            count = self._plan()
            self._encode(count)
            core.lib.oizys_damage_presented(ctypes.byref(self.map))
            wall.append((time.perf_counter() - started) * 1000)
        return wall


def bar(fraction: float, width: int = 24) -> str:
    filled = int(round(fraction * width))
    return "#" * filled + "." * (width - filled)


def report(rows, wall, title):
    total = next((r["total_ms"] for r in rows if r["zone"] == "present frame"), 0.0)
    if total <= 0:
        total = max((r["total_ms"] for r in rows), default=1.0)

    print(f"\n{title}")
    print(f"{'zone':<18}{'calls':>10}{'total ms':>11}{'self ms':>10}{'self':>7}  "
          f"{'':<24} {'ns/call':>10}")
    print("-" * 96)
    for row in rows:
        indent = "  " * row["depth"]
        share = row["self_ms"] / total if total else 0
        print(f"{indent + row['zone']:<18}{row['calls']:>10}{row['total_ms']:>11.3f}"
              f"{row['self_ms']:>10.3f}{share * 100:>6.1f}%  {bar(share)} "
              f"{row['total_ms'] * 1e6 / row['calls']:>10.0f}")

    print()
    print(f"frames            {len(wall)}")
    print(f"wall per frame    {statistics.mean(wall):.3f} ms mean, "
          f"{statistics.median(wall):.3f} median, {max(wall):.3f} worst")
    print(f"60 Hz budget      {1000 / 60:.2f} ms per head, "
          f"{statistics.mean(wall) * 2 / (1000 / 60) * 100:.0f}% used by two heads")


def compare(rows, baseline_path):
    baseline = {r["zone"]: r for r in json.loads(pathlib.Path(baseline_path).read_text())["zones"]}
    print(f"\nagainst {baseline_path}")
    print(f"{'zone':<18}{'before ms':>11}{'after ms':>11}{'change':>10}")
    print("-" * 52)
    regressed = False
    for row in rows:
        was = baseline.get(row["zone"])
        if not was:
            continue
        delta = row["self_ms"] - was["self_ms"]
        percent = (delta / was["self_ms"] * 100) if was["self_ms"] else 0
        flag = ""
        if percent > 10:
            flag, regressed = "  REGRESSED", True
        elif percent < -10:
            flag = "  improved"
        print(f"{'  ' * row['depth'] + row['zone']:<18}{was['self_ms']:>11.3f}"
              f"{row['self_ms']:>11.3f}{percent:>9.1f}%{flag}")
    return 1 if regressed else 0


def main():
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--frames", type=int, default=120)
    parser.add_argument("--workload", choices=["desktop", "keyframe"], default="desktop")
    parser.add_argument("--save", metavar="FILE")
    parser.add_argument("--compare", metavar="FILE")
    args = parser.parse_args()

    workload = Workload(args.frames)
    core.lib.oizys_profile_reset()
    core.lib.oizys_profile_enable(1)
    wall = workload.run(args.workload)
    core.lib.oizys_profile_enable(0)

    rows = zone_stats()
    report(rows, wall, f"scanout profile: {args.workload}, {WIDTH}x{HEIGHT}")

    if args.save:
        pathlib.Path(args.save).write_text(json.dumps(
            {"workload": args.workload, "frames": args.frames,
             "wall_ms_mean": statistics.mean(wall), "zones": rows}, indent=2))
        print(f"\nsaved to {args.save}")

    if args.compare:
        return compare(rows, args.compare)
    return 0


if __name__ == "__main__":
    sys.exit(main())
