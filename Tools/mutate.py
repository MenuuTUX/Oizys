#!/usr/bin/env python3
"""Mutation testing.

Coverage says a line ran. It does not say a test would have noticed the line being wrong.
This makes small, plausible edits -- a comparison flipped, a constant off by one, a shift
reversed -- rebuilds the library, and runs the suite. A mutant the suite still passes is a
hole: that line executes but nothing depends on its value.

Every operator here mirrors a mistake actually made in this codebase. The luma ceiling bug
was a constant off by one; a Haar sign flip survived the suite until the differential
model was written.

    python3 Tools/mutate.py                 every target
    python3 Tools/mutate.py wht.c           one file
    python3 Tools/mutate.py --limit 40
"""
from __future__ import annotations

import argparse
import os
import pathlib
import random
import re
import shutil
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
SRC = ROOT / "Sources" / "MViewCore"
BUILD = ROOT / "build" / "mutants"
PYTHON = ROOT / ".venv" / "bin" / "python"

# Suites run in order and stop at the first kill, so the cheapest and most specific first.
TARGETS = {
    "wht.c": ["Tests/test_codec.py", "Tests/test_wire.py"],
    "encode.c": ["Tests/test_damage.py", "Tests/test_codec.py"],
    "dl3.c": ["Tests/test_protocol.py"],
    "crypto.c": ["Tests/test_crypto.py"],
}

OPERATORS = [
    (r"(?<![<>=!+\-*/&|^])\+(?![+=])", "-", "+ becomes -"),
    (r"(?<![<>=!+\-*/&|^])-(?![-=>])", "+", "- becomes +"),
    (r"<<", ">>", "left shift becomes right"),
    (r">>", "<<", "right shift becomes left"),
    (r"<=", "<", "<= becomes <"),
    (r">=", ">", ">= becomes >"),
    (r"(?<![<>=!])<(?![<=])", "<=", "< becomes <="),
    (r"(?<![<>=!])>(?![>=])", ">=", "> becomes >="),
    (r"==", "!=", "== becomes !="),
    (r"!=", "==", "!= becomes =="),
    (r"&&", "||", "&& becomes ||"),
    (r"\|\|", "&&", "|| becomes &&"),
    (r"\b(\d+)\b", None, "constant off by one"),
]

SKIP_LINE = re.compile(r"^\s*(//|\*|/\*|#include|#ifndef|#define MVIEW_\w+_H)")


def strip_block_comments(text: str) -> str:
    """Blank /* ... */ spans, newlines preserved so line numbers stay aligned. Done over
    the whole file: a block comment's continuation lines look like code to a per-line
    matcher, which had this tool reporting comment prose as surviving mutants."""
    out, i = [], 0
    while i < len(text):
        if text.startswith("/*", i):
            end = text.find("*/", i + 2)
            end = len(text) if end < 0 else end + 2
            out.append("".join(c if c == "\n" else " " for c in text[i:end]))
            i = end
        else:
            out.append(text[i])
            i += 1
    return "".join(out)


def mutation_sites(text: str):
    sites = []
    decommented = strip_block_comments(text).splitlines()
    for index, raw in enumerate(text.splitlines()):
        if SKIP_LINE.match(raw) or not raw.strip():
            continue
        line = decommented[index] if index < len(decommented) else raw
        line = re.sub(r'"(?:[^"\\]|\\.)*"', lambda m: " " * len(m.group()), line)
        line = re.sub(r"//.*", lambda m: " " * len(m.group()), line)
        for pattern, replacement, description in OPERATORS:
            for match in re.finditer(pattern, line):
                if replacement is None:
                    try:
                        value = int(match.group(1))
                    except (ValueError, IndexError):
                        continue
                    if value > 1 << 20:
                        continue
                    new = str(value + 1)
                else:
                    new = replacement
                sites.append((index, match.start(), match.end(), new, description))
    return sites


def apply(text: str, site) -> str:
    index, start, end, new, _ = site
    lines = text.splitlines(keepends=True)
    lines[index] = lines[index][:start] + new + lines[index][end:]
    return "".join(lines)


def build_library(workdir: pathlib.Path):
    """Compile the mutated tree straight to a dylib. Going through xcodebuild for every
    mutant would spend most of the run in the build system."""
    sdk = subprocess.run(["xcrun", "--show-sdk-path"], capture_output=True,
                         text=True).stdout.strip()
    output = workdir / "libMViewCore.dylib"
    sources = [str(p) for p in sorted(workdir.glob("*.c"))]
    sources += [str(p) for p in sorted(SRC.glob("*.m"))]
    command = [
        "xcrun", "clang", "-dynamiclib", "-std=c11", "-w", "-O1", "-mcpu=apple-m3",
        "-isysroot", sdk, f"-I{SRC}/include", "-fobjc-arc", "-o", str(output), *sources,
        "-framework", "Foundation", "-framework", "CoreFoundation", "-framework",
        "CoreGraphics", "-framework", "CoreMedia", "-framework", "CoreVideo",
        "-framework", "IOKit", "-framework", "IOUSBHost", "-framework", "Security",
        "-framework", "ScreenCaptureKit", "-framework", "ImageIO",
        "-framework", "UniformTypeIdentifiers",
    ]
    result = subprocess.run(command, capture_output=True, text=True, timeout=180)
    if result.returncode != 0:
        first = (result.stderr.strip().splitlines() or ["?"])[0]
        return None, first
    return output, None


def run_suites(library: pathlib.Path, suites) -> str:
    env = dict(os.environ, MVIEW_DYLIB=str(library), PYTHONDONTWRITEBYTECODE="1")
    for suite in suites:
        try:
            result = subprocess.run([str(PYTHON), "-m", "pytest", suite, "-x", "-q",
                                     "--no-header", "-p", "no:cacheprovider"],
                                    cwd=ROOT, env=env, capture_output=True, timeout=300)
        except subprocess.TimeoutExpired:
            return "killed"  # a mutant that hangs is a detected defect
        if result.returncode != 0:
            return "killed"
    return "survived"


def main():
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("files", nargs="*")
    parser.add_argument("--limit", type=int, default=40, help="mutants per file")
    parser.add_argument("--seed", type=int, default=1)
    args = parser.parse_args()

    if not PYTHON.exists():
        sys.exit("run Tools/test.py once first, to create .venv")

    random.seed(args.seed)
    BUILD.mkdir(parents=True, exist_ok=True)
    survivors, killed_total, survived_total = [], 0, 0

    for name in args.files or list(TARGETS):
        if name not in TARGETS:
            print(f"no suite mapped for {name}; known: {', '.join(TARGETS)}")
            continue
        suites = TARGETS[name]
        original = (SRC / name).read_text()
        sites = mutation_sites(original)
        random.shuffle(sites)
        sites = sites[:args.limit]
        print(f"\n{name}: {len(sites)} mutants against {', '.join(suites)}")

        killed = survived = skipped = 0
        first_error = None
        workdir = BUILD / name.replace(".", "_")
        shutil.rmtree(workdir, ignore_errors=True)
        workdir.mkdir(parents=True)
        for source in SRC.glob("*.c"):
            shutil.copy(source, workdir / source.name)

        for number, site in enumerate(sites, 1):
            (workdir / name).write_text(apply(original, site))
            library, error = build_library(workdir)
            if library is None:
                skipped += 1
                first_error = first_error or error
                mark = "."
            elif run_suites(library, suites) == "killed":
                killed += 1
                mark = "x"
            else:
                survived += 1
                mark = "!"
                line = site[0]
                survivors.append((name, line + 1, site[4],
                                  original.splitlines()[line].strip()[:76]))
            print(mark, end="", flush=True)
            if number % 50 == 0:
                print()
        print()
        viable = killed + survived
        print(f"  killed {killed}, survived {survived}, uncompilable {skipped}"
              f"  -> {100.0 * killed / viable if viable else 0:.0f}% of viable mutants caught")
        if skipped and not viable:
            print(f"  every mutant failed to build, so the harness is broken rather than the\n"
                  f"  code unmutatable: {first_error}")
        killed_total += killed
        survived_total += survived

    if survivors:
        print("\nSurvivors (the line runs, but nothing asserts on what it produces):")
        for name, line, description, text in survivors:
            print(f"  {name}:{line}  {description}\n      {text}")

    total = killed_total + survived_total
    print(f"\nmutation score: {killed_total}/{total} "
          f"({100.0 * killed_total / total if total else 0:.0f}%)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
