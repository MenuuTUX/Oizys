#!/usr/bin/env python3
"""Turn a run directory of logs, process samples and profiles into one readable README.

    python3 Tools/report.py logs/latency-20260830
    python3 Tools/report.py logs/latency-20260830 --title "ZLP fix, three runs"
    python3 Tools/report.py logs/run.log build/profile.json -o logs/report

Reads whatever it recognises and ignores the rest:

  *.log                driver output. Latency lines, scanout lines, and everything that
                       looks like a failure.
  *.json  (samples)    Tools/measure_processes.py output: [{elapsed, processes:{pid:...}}]
  *.json  (zones)      Tools/profile.py --save output: {workload, frames, zones:[...]}

Writes README.md next to the inputs, with the charts beside it as .svg files. Markdown
tables and a linked SVG render on GitHub, in an editor preview and in a terminal pager;
an HTML dashboard renders in one of those three.

Nothing here runs the driver or touches the build. It reads files that already exist, so
it is safe to point at a run someone else recorded.
"""
from __future__ import annotations

import argparse
import collections
import json
import pathlib
import re
import statistics
import sys

# head 0 latency: samples=260 replaced=0 capture-age-at-USB samples=260 mean=1.56ms
# max=10.50ms processing mean=3.17ms max=14.41ms
LATENCY = re.compile(
    r"head (?P<head>\d+) latency: samples=(?P<samples>\d+) replaced=(?P<replaced>\d+).*?"
    r"capture-age-at-USB samples=\d+ mean=(?P<age_mean>[\d.]+)ms max=(?P<age_max>[\d.]+)ms"
    r".*?processing mean=(?P<proc_mean>[\d.]+)ms max=(?P<proc_max>[\d.]+)ms")
# head 0 scanout: frame 1024, 37 of 2040 strips (keyframe)
SCANOUT = re.compile(
    r"head (?P<head>\d+) scanout: frame (?P<frame>\d+), (?P<strips>\d+) of (?P<total>\d+) strips"
    r"(?P<keyframe> \(keyframe\))?")
FAILURE = re.compile(r"fail|error|refus|timed out|timeout|retry|retrying|stopped responding"
                     r"|disconnect|underrun|0x[0-9a-f]{8}", re.IGNORECASE)
# Timestamps, pids, addresses and counters differ line to line; the shape of the message
# is what a reader is grouping by.
VARIABLE = re.compile(r"\b0x[0-9a-fA-F]+\b|\b\d[\d.:]*\b")


def percentile(values, fraction):
    """Nearest-rank, so a p99 of 40 samples is a sample that happened, not an average of
    two that did not."""
    if not values:
        return 0.0
    ordered = sorted(values)
    index = min(len(ordered) - 1, max(0, round(fraction * len(ordered)) - 1))
    return ordered[index]


def read_log(path):
    heads = collections.defaultdict(lambda: {"proc_mean": [], "proc_max": [], "age_mean": [],
                                             "age_max": [], "samples": 0, "replaced": 0})
    strips = collections.defaultdict(list)
    keyframes = collections.Counter()
    failures = collections.Counter()
    lines = 0
    for line in path.read_text(errors="replace").splitlines():
        lines += 1
        match = LATENCY.search(line)
        if match:
            head = heads[int(match["head"])]
            head["proc_mean"].append(float(match["proc_mean"]))
            head["proc_max"].append(float(match["proc_max"]))
            head["age_mean"].append(float(match["age_mean"]))
            head["age_max"].append(float(match["age_max"]))
            head["samples"] += int(match["samples"])
            head["replaced"] += int(match["replaced"])
            continue
        match = SCANOUT.search(line)
        if match:
            strips[int(match["head"])].append((int(match["strips"]), int(match["total"])))
            if match["keyframe"]:
                keyframes[int(match["head"])] += 1
            continue
        if FAILURE.search(line):
            failures[VARIABLE.sub("N", line.strip())] += 1
    return {"path": path, "lines": lines, "heads": dict(heads), "strips": dict(strips),
            "keyframes": keyframes, "failures": failures}


def read_json(path):
    try:
        data = json.loads(path.read_text())
    except (json.JSONDecodeError, UnicodeDecodeError):
        return None
    if isinstance(data, dict) and "zones" in data:
        return {"kind": "profile", "path": path, "data": data}
    if isinstance(data, list) and data and isinstance(data[0], dict) and "processes" in data[0]:
        return {"kind": "samples", "path": path, "data": data}
    return None


def process_series(samples):
    """CPU percent between consecutive samples, and RSS, per process. Cumulative CPU
    seconds differenced over wall time: 100% is one core busy, which is the number that
    matters for a driver that has one encoder thread per head."""
    series = {}
    for previous, current in zip(samples, samples[1:]):
        window = current["elapsed"] - previous["elapsed"]
        if window <= 0:
            continue
        for pid, entry in current["processes"].items():
            was = previous["processes"].get(pid)
            if not was:
                continue
            row = series.setdefault(pid, {"name": entry["name"], "cpu": [], "rss": []})
            row["cpu"].append((entry["cpu_seconds"] - was["cpu_seconds"]) / window * 100)
            row["rss"].append(entry["rss_kib"] / 1024)
    return series


def svg_lines(path, series, title, unit, width=880):
    """One SVG per chart, referenced from the README. Deliberately hand-rolled: a chart
    library would be a dependency for eight elements, and the report has to render on a
    machine that has only the repo.

    Runs of different lengths are drawn across the same width, so the x axis is progress
    through a run rather than wall time; the caption says so. Two runs of unequal length
    are still worth putting on one chart, and rescaling the short one to a fraction of the
    width makes it unreadable to save a comparison nobody was making."""
    series = [(name, values) for name, values in series if values]
    if not series:
        return None
    # A folder holding a dozen runs is fifty lines on one chart, which is a colour swatch
    # rather than a comparison. Keep the busiest and leave the rest to the table, which
    # still lists every one.
    dropped = 0
    if len(series) > 12:
        series.sort(key=lambda entry: max(entry[1]), reverse=True)
        dropped = len(series) - 12
        series = series[:12]
    top = max(max(values) for _, values in series) or 1.0
    colours = ["#2459bb", "#bb4524", "#2f8f4e", "#8b47b5", "#b58a24", "#3aa0a8",
               "#7a5c3a", "#c0399f", "#4a4a4a", "#1f7a8c"]
    columns = 2
    rows = (len(series) + columns - 1) // columns
    plot_height, legend_top = 250, 268
    height = legend_top + rows * 16 + 26
    left, right, base, cap = 56, width - 16, plot_height - 24, 34
    body, legend = [], []
    for index, (name, values) in enumerate(series):
        step = (right - left) / max(len(values) - 1, 1)
        points = " ".join(f"{left + i * step:.1f},{base - value / top * (base - cap):.1f}"
                          for i, value in enumerate(values))
        colour = colours[index % len(colours)]
        body.append(f'<polyline points="{points}" fill="none" stroke="{colour}" '
                    f'stroke-width="1.8" stroke-opacity="0.9"/>')
        x = 12 + (index // rows) * (width - 24) / columns
        y = legend_top + (index % rows) * 16
        legend.append(f'<rect x="{x:.0f}" y="{y - 8}" width="10" height="10" fill="{colour}"/>'
                      f'<text x="{x + 16:.0f}" y="{y + 1}" font-family="sans-serif" '
                      f'font-size="11" fill="#333">{name} ({len(values)})</text>')
    grid = []
    for fraction in (0.0, 0.25, 0.5, 0.75, 1.0):
        y = base - fraction * (base - cap)
        grid.append(f'<line x1="{left}" y1="{y:.1f}" x2="{right}" y2="{y:.1f}" stroke="#e4e4e4"/>'
                    f'<text x="8" y="{y + 4:.1f}" font-family="sans-serif" font-size="11" '
                    f'fill="#666">{top * fraction:.1f}</text>')
    path.write_text(
        f'<svg xmlns="http://www.w3.org/2000/svg" width="{width}" height="{height}" '
        f'viewBox="0 0 {width} {height}">'
        f'<rect width="{width}" height="{height}" fill="white"/>'
        f'<text x="8" y="20" font-family="sans-serif" font-size="14">{title} ({unit})</text>'
        f'{"".join(grid)}{"".join(body)}'
        f'<text x="{left}" y="{plot_height + 4}" font-family="sans-serif" font-size="11" '
        f'fill="#666">Each line spans its own run left to right; the count after a name is '
        f'how many samples it has.'
        + (f' {dropped} quieter series are in the table only.' if dropped else '')
        + f'</text>{"".join(legend)}</svg>')
    return path.name


def table(headers, rows, align_left=(0,)):
    if not rows:
        return "_no samples_\n"
    out = ["| " + " | ".join(headers) + " |",
           "|" + "|".join("---" if i in align_left else "---:"
                          for i in range(len(headers))) + "|"]
    out += ["| " + " | ".join(str(cell) for cell in row) + " |" for row in rows]
    return "\n".join(out) + "\n"


def bar(fraction, width=20):
    filled = max(0, min(width, int(round(fraction * width))))
    return "█" * filled + "·" * (width - filled)


def latency_section(logs, folder):
    rows, chart = [], []
    for log in logs:
        for head, stats in sorted(log["heads"].items()):
            means = stats["proc_mean"]
            rows.append([log["path"].name, head, stats["samples"], stats["replaced"],
                         f"{statistics.mean(means):.2f}", f"{percentile(stats['proc_max'], 0.95):.2f}",
                         f"{max(stats['proc_max']):.2f}",
                         f"{statistics.mean(stats['age_mean']):.2f}",
                         f"{max(stats['age_max']):.2f}",
                         f"{statistics.mean(means) / (1000 / 60) * 100:.0f}%"])
            chart.append((f"{log['path'].stem} head {head}", means))
    if not rows:
        return ""
    name = svg_lines(folder / "processing.svg", chart,
                     "Mean frame processing time per report window", "ms")
    text = ["## Frame latency\n",
            "`processing` is capture callback to USB submission. `capture age` is how old "
            "the frame already was when the driver got it, which is the compositor's share "
            "and not something the encoder can win back. One 60 Hz head has 16.67 ms.\n",
            table(["log", "head", "frames", "replaced", "mean ms", "p95 of maxima",
                   "worst ms", "capture age mean", "capture age worst", "of 60 Hz budget"],
                  rows)]
    if name:
        text.append(f"\n![Processing time]({name})\n")
    return "\n".join(text)


def strips_section(logs):
    rows = []
    for log in logs:
        for head, samples in sorted(log["strips"].items()):
            counts = [count for count, _ in samples]
            total = samples[0][1]
            rows.append([log["path"].name, head, len(samples), total,
                         f"{statistics.mean(counts):.0f}",
                         f"{percentile(counts, 0.95)}", max(counts),
                         f"{statistics.mean(counts) / total * 100:4.1f}% "
                         f"{bar(statistics.mean(counts) / total)}",
                         log["keyframes"][head]])
    if not rows:
        return ""
    return ("## What actually went on the wire\n\n"
            "Strips sent per frame against the strips a whole surface would be. This is the "
            "damage tracker's whole point: a number near the total means the driver is "
            "paying for a full raster every frame.\n\n"
            + table(["log", "head", "frames logged", "strips in a surface", "mean sent",
                     "p95", "worst", "share of surface", "keyframes"], rows))


def failure_section(logs):
    merged = collections.Counter()
    for log in logs:
        merged.update(log["failures"])
    if not merged:
        return "## Failures\n\nNothing in these logs matched a failure pattern.\n"
    rows = [[count, f"`{line[:150]}`"] for line, count in merged.most_common(25)]
    return ("## Failures, grouped\n\n"
            "Digits and hex are replaced with `N` so the same message with a different "
            "counter groups into one row. Read the count first: one occurrence of a bulk "
            "write error is the link renegotiating, two hundred is the link failing.\n\n"
            + table(["times", "message"], rows, align_left=(1,)))


def profile_section(profiles):
    if not profiles:
        return ""
    text = ["## Encoder profile\n"]
    for entry in profiles:
        data = entry["data"]
        zones = data["zones"]
        total = next((z["total_ms"] for z in zones if z["zone"] == "present frame"), 0.0) \
            or max((z["total_ms"] for z in zones), default=1.0)
        rows = [["&nbsp;" * 2 * z["depth"] + z["zone"], z["calls"], f"{z['total_ms']:.3f}",
                 f"{z['self_ms']:.3f}",
                 f"{z['self_ms'] / total * 100:4.1f}% {bar(z['self_ms'] / total)}",
                 f"{z['total_ms'] * 1e6 / z['calls']:.0f}"] for z in zones]
        text.append(f"\n**{entry['path'].name}** — workload `{data.get('workload', '?')}`, "
                    f"{data.get('frames', '?')} frames, "
                    f"{data.get('wall_ms_mean', 0):.3f} ms mean wall per frame.\n")
        text.append("Zones nest, so a child's time is inside its parent's total. Read the "
                    "self column for where the time is.\n")
        text.append(table(["zone", "calls", "total ms", "self ms", "share of frame",
                           "ns/call"], rows))
    return "\n".join(text)


def process_section(samples_files, folder):
    if not samples_files:
        return ""
    rows, cpu_chart, rss_chart = [], [], []
    for entry in samples_files:
        for pid, row in sorted(process_series(entry["data"]).items()):
            if not row["cpu"]:
                continue
            label = pathlib.Path(row["name"]).name
            rows.append([entry["path"].name, pid, label,
                         f"{statistics.mean(row['cpu']):.1f}%",
                         f"{max(row['cpu']):.1f}%",
                         f"{max(row['rss']):.1f}"])
            cpu_chart.append((f"{label} ({pid})", row["cpu"]))
            rss_chart.append((f"{label} ({pid})", row["rss"]))
    if not rows:
        return ""
    cpu = svg_lines(folder / "cpu.svg", cpu_chart, "CPU per process", "% of one core")
    rss = svg_lines(folder / "rss.svg", rss_chart, "Resident memory per process", "MiB")
    text = ["## Cost on the machine\n",
            "100% is one core. WindowServer is here because a driver that moves work into "
            "the compositor has not saved anything.\n",
            table(["samples", "pid", "process", "mean CPU", "peak CPU", "peak RSS MiB"], rows)]
    if cpu:
        text.append(f"\n![CPU]({cpu})\n")
    if rss:
        text.append(f"\n![RSS]({rss})\n")
    return "\n".join(text)


def collect(inputs):
    logs, profiles, samples = [], [], []
    files = []
    for item in inputs:
        files.extend(sorted(item.rglob("*")) if item.is_dir() else [item])
    for path in files:
        if path.suffix == ".log" or path.suffix == ".txt" and "summary" not in path.name:
            logs.append(read_log(path))
        elif path.suffix == ".json":
            parsed = read_json(path)
            if parsed and parsed["kind"] == "profile":
                profiles.append(parsed)
            elif parsed:
                samples.append(parsed)
    return logs, profiles, samples


def main():
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("inputs", nargs="+", type=pathlib.Path,
                        help="log files, profile/sample JSON, or directories of them")
    parser.add_argument("-o", "--output", type=pathlib.Path,
                        help="folder for README.md and the charts (default: the first input)")
    parser.add_argument("--title", default="Run report")
    args = parser.parse_args()

    folder = args.output or (args.inputs[0] if args.inputs[0].is_dir()
                             else args.inputs[0].parent)
    folder.mkdir(parents=True, exist_ok=True)
    logs, profiles, samples = collect(args.inputs)
    if not (logs or profiles or samples):
        sys.exit("nothing recognisable in those inputs")

    sections = [
        f"# {args.title}\n",
        f"Generated by `Tools/report.py` from {len(logs)} logs, {len(profiles)} profiles and "
        f"{len(samples)} process samples. Every number below comes from a file in this "
        "folder; nothing was measured while writing it.\n",
        latency_section(logs, folder),
        strips_section(logs),
        profile_section(profiles),
        process_section(samples, folder),
        failure_section(logs),
        "## Inputs\n\n" + table(["file", "detail"],
                                [[f"`{log['path'].name}`", log["lines"]] for log in logs]
                                + [[f"`{p['path'].name}`", "profile"] for p in profiles]
                                + [[f"`{s['path'].name}`", f"{len(s['data'])} samples"]
                                   for s in samples]),
        "## What this does not say\n\n"
        "Nothing here measures panel latency, colour accuracy or what a person sees. "
        "Processing time ends at the USB submission; everything after that is the dock. "
        "Logs can name paths and device serials, so read one before sending it on.\n",
    ]
    readme = folder / "README.md"
    readme.write_text("\n".join(section for section in sections if section))
    print(f"wrote {readme}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
