"""Sample process CPU/RSS during a bounded motion comparison. Does not control drivers.

CPU comes from changes in cumulative process CPU time, not ps's smoothed %CPU estimate.
100% means one CPU core. Include WindowServer and the workload separately from the driver.
"""
import argparse
import json
import pathlib
import subprocess
import time


def cpu_seconds(value):
    days, _, clock = value.rpartition("-")
    parts = [float(part) for part in clock.split(":")]
    seconds = sum(part * 60 ** index for index, part in enumerate(reversed(parts)))
    return seconds + (int(days) * 86400 if days else 0)


def snapshot():
    output = subprocess.check_output(["ps", "-axo", "pid=,time=,rss=,comm="], text=True)
    processes = {}
    for line in output.splitlines():
        fields = line.split(None, 3)
        if len(fields) != 4:
            continue
        pid, cpu, rss, name = fields
        if any(part in name for part in ("DisplayLink", "mview", "WindowServer", "MotionBench",
                                         "/MView.app/Contents/MacOS/MView")):
            processes[pid] = {"name": name, "cpu_seconds": cpu_seconds(cpu), "rss_kib": int(rss)}
    return processes


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("output", type=pathlib.Path)
    parser.add_argument("--seconds", type=int, default=25)
    args = parser.parse_args()
    started = time.monotonic()
    samples = []
    while True:
        samples.append({"elapsed": time.monotonic() - started, "processes": snapshot()})
        if time.monotonic() - started >= args.seconds:
            break
        time.sleep(1)
    args.output.write_text(json.dumps(samples, indent=2) + "\n")
    pids = {pid for sample in samples for pid in sample["processes"]}
    for pid in sorted(pids, key=int):
        observed = [(s["elapsed"], s["processes"][pid]) for s in samples if pid in s["processes"]]
        if len(observed) < 2:
            continue
        start, first = observed[0]
        end, last = observed[-1]
        cpu = 100 * (last["cpu_seconds"] - first["cpu_seconds"]) / (end - start)
        peak = max(p["rss_kib"] for _, p in observed) / 1024
        print(f"{pid:>6} {cpu:6.1f}% CPU {peak:7.1f} MiB peak RSS "
              f"over {end-start:.1f}s {first['name']}")


if __name__ == "__main__":
    main()
