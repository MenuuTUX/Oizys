#!/usr/bin/env python3
"""Build the library and run the suite.

    python3 Tools/test.py                 build, then run every suite
    python3 Tools/test.py -k damage       pass through to pytest
    python3 Tools/test.py --sanitize address
    python3 Tools/test.py --coverage [--coverage-floor 80]
    python3 Tools/test.py --mutate

The tests drive libMViewCore.dylib through ctypes, so a sanitiser run means building the
library with the sanitiser and letting the same Python suite drive it. Nothing about the
tests changes.
"""
from __future__ import annotations

import argparse
import json
import os
import pathlib
import shutil
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
VENV = ROOT / ".venv"
PYTHON = VENV / "bin" / "python"
PROJECT = ROOT / "MView.xcodeproj"

SANITIZERS = {
    "address": "-fsanitize=address,undefined -fno-omit-frame-pointer",
    "undefined": "-fsanitize=undefined -fno-sanitize-recover=all",
    "thread": "-fsanitize=thread",
}


def ensure_venv() -> pathlib.Path:
    if PYTHON.exists():
        return PYTHON
    print("creating .venv and installing pytest, hypothesis, numpy")
    subprocess.run([sys.executable, "-m", "venv", str(VENV)], check=True)
    subprocess.run([str(VENV / "bin" / "pip"), "install", "--quiet",
                    "--disable-pip-version-check", "pytest", "hypothesis", "numpy"], check=True)
    return PYTHON


def build(configuration="Release", extra_cflags="", extra_ldflags=""):
    command = ["xcodebuild", "-project", str(PROJECT), "-target", "MViewCoreDylib",
               "-configuration", configuration, "build"]
    if extra_cflags:
        command.append(f"OTHER_CFLAGS=$(inherited) {extra_cflags}")
        command.append(f"OTHER_LDFLAGS=$(inherited) {extra_ldflags or extra_cflags}")
    result = subprocess.run(command, capture_output=True, text=True, cwd=ROOT)
    if "BUILD SUCCEEDED" not in result.stdout:
        print(result.stdout[-4000:])
        sys.exit("library build failed")
    for line in result.stdout.splitlines():
        if "BUILT_PRODUCTS_DIR" in line:
            return pathlib.Path(line.split("=", 1)[1].strip())
    return ROOT / "build" / configuration


def run_pytest(python, extra_args, environment=None):
    env = dict(os.environ)
    env.setdefault("PYTHONDONTWRITEBYTECODE", "1")
    if environment:
        env.update(environment)
    return subprocess.run([str(python), "-m", "pytest", "Tests", "-q", *extra_args],
                          cwd=ROOT, env=env).returncode


def coverage(python, passthrough, floor):
    """llvm-cov over the library while the Python suite drives it."""
    products = build("Debug", "-fprofile-instr-generate -fcoverage-mapping")
    raw = ROOT / "build" / "coverage"
    shutil.rmtree(raw, ignore_errors=True)
    raw.mkdir(parents=True)
    code = run_pytest(python, passthrough, {
        "LLVM_PROFILE_FILE": str(raw / "%p.profraw"),
        # Without this the suite would load whichever library it finds first, which is
        # usually the uninstrumented Release build, and write no profile at all.
        "MVIEW_DYLIB": str(products / "libMViewCore.dylib"),
    })
    profiles = sorted(raw.glob("*.profraw"))
    if not profiles:
        sys.exit("no profile data was written")
    merged = raw / "merged.profdata"
    subprocess.run(["xcrun", "llvm-profdata", "merge", "-sparse", *map(str, profiles),
                    "-o", str(merged)], check=True)
    library = products / "libMViewCore.dylib"
    core = ROOT / "Sources" / "MViewCore"
    # The files a test can reach with no dock plugged in. driver.c, usb_probe.c,
    # usb_session.c, ddc_native.c, display.c and capture_frame.c all need real hardware or
    # a real display server to enter.
    reachable = [str(core / name) for name in
                 ("wht.c", "encode.c", "dl3.c", "crypto.c", "profile.c", "config.c")]
    everything = sorted(str(p) for p in core.glob("*.c"))

    # Both numbers, always. The first says how well the code the suite can actually run is
    # tested; the second says how much of the driver that is. Printing only the first
    # reads as 84% coverage of MView, which is not what it measures -- the files it leaves
    # out are most of the driver and all of the parts that touch the dock.
    print("\n=== reachable without hardware: what the suite covers ===", flush=True)
    subprocess.run(["xcrun", "llvm-cov", "report", str(library),
                    f"-instr-profile={merged}", *reachable], cwd=ROOT)
    print("\n=== every C file in the library, including the hardware paths ===", flush=True)
    subprocess.run(["xcrun", "llvm-cov", "report", str(library),
                    f"-instr-profile={merged}", *everything], cwd=ROOT)
    # Four sources are tested, but not through this library. Their suites compile
    # Tests/Support/*.c, which #includes the source directly so it can be driven with
    # mock hardware, into a separate uninstrumented dylib. Reading their 0% here as
    # "untested" is the opposite of the truth.
    print("\nusb_session.c, ddc_native.c, capture_frame.c and supervisor.c read 0% above "
          "because their tests compile them separately, through Tests/Support/*.c, rather "
          "than through this library. What genuinely has no test is driver.c, usb_probe.c, "
          "display.c and bench.c.", flush=True)

    swift = sorted((ROOT / "Sources/MViewPlatform").glob("*.swift")) + \
            sorted((ROOT / "Sources/MViewApp").glob("*.swift"))
    swift_lines = sum(len(p.read_text().splitlines()) for p in swift)
    print(f"\nSwift: {swift_lines} lines in {len(swift)} files, 0% covered. The suite drives "
          "the library through ctypes and never enters Swift; ScreenCaptureKit, the virtual "
          "displays and the menu-bar app are exercised only by a live run against the dock.")

    subprocess.run(["xcrun", "llvm-cov", "show", str(library), f"-instr-profile={merged}",
                    "-format=html", f"-output-dir={raw / 'html'}", *everything],
                   cwd=ROOT, capture_output=True)
    print(f"\nhtml report: {(raw / 'html' / 'index.html').relative_to(ROOT)}")

    summary = json.loads(subprocess.run(
        ["xcrun", "llvm-cov", "export", "--summary-only", str(library),
         f"-instr-profile={merged}", *reachable],
        cwd=ROOT, capture_output=True, text=True, check=True).stdout)
    lines = summary["data"][0]["totals"]["lines"]
    percent = lines["percent"]
    (raw / "summary.json").write_text(json.dumps(summary["data"][0]["totals"], indent=2))
    print(f"\nreachable line coverage: {percent:.2f}% "
          f"({lines['covered']}/{lines['count']}), floor {floor:.2f}%")
    # A crashed interpreter writes no counters at all, and every file then reports 0.00%
    # while the run still exits through this function. That reads as "coverage collapsed"
    # rather than "the suite died", so fail on it here instead of letting a green tick
    # carry a report full of zeroes.
    if percent < floor:
        print(f"coverage {percent:.2f}% is below the {floor:.2f}% floor")
        return code or 1
    return code


def native_sanitizer_run(flags):
    """Compile Tests/Support/asan_runner.c with the pure-logic sources under the sanitiser
    and run it directly. Our own binary, so the sanitizer loads with no platform policy in
    the way -- unlike injecting it into the Apple-signed Python host."""
    pure = ["config.c", "encode.c", "wht.c", "crypto.c", "dl3.c", "profile.c", "log.c"]
    sources = [str(ROOT / "Sources/MViewCore" / name) for name in pure]
    binary = ROOT / "build" / "asan_runner"
    binary.parent.mkdir(parents=True, exist_ok=True)
    command = ["xcrun", "clang", "-std=c11", "-fblocks", "-g", "-O1",
               "-mcpu=apple-m1", "-DMVIEW_LOG_IMPLEMENTATION",
               "-I", str(ROOT / "Sources/MViewCore/include"),
               *flags.split(), str(ROOT / "Tests/Support/asan_runner.c"), *sources,
               # crypto.c calls SecKey for RSA-OAEP; dl3/log touch CoreFoundation.
               "-framework", "Security", "-framework", "CoreFoundation",
               "-o", str(binary)]
    build_result = subprocess.run(command, capture_output=True, text=True)
    if build_result.returncode != 0:
        print(build_result.stderr[-4000:])
        sys.exit("address-sanitiser runner failed to build")
    print("running the address+undefined sanitiser runner")
    env = dict(os.environ, ASAN_OPTIONS="detect_leaks=0:abort_on_error=1",
               UBSAN_OPTIONS="halt_on_error=1:print_stacktrace=1")
    return subprocess.run([str(binary)], cwd=ROOT, env=env).returncode


def main():
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--sanitize", choices=sorted(SANITIZERS))
    parser.add_argument("--coverage", action="store_true")
    parser.add_argument("--coverage-floor", type=float, default=1.0,
                        metavar="PERCENT",
                        help="fail if reachable line coverage falls below this")
    parser.add_argument("--mutate", action="store_true")
    parser.add_argument("--configuration", default="Release")
    known, passthrough = parser.parse_known_args()

    python = ensure_venv()

    if known.mutate:
        return subprocess.run([str(python), str(ROOT / "Tools" / "mutate.py"),
                               *passthrough], cwd=ROOT).returncode
    if known.coverage:
        return coverage(python, passthrough, known.coverage_floor)
    if known.sanitize:
        # Address sanitiser runs as a native binary, not through the Python suite. macOS
        # refuses to load a sanitizer runtime into the Apple-signed interpreter ("Sanitizer
        # load violates platform policy"), so the ctypes path cannot host ASan at all. The
        # runner compiles the pure-logic sources itself and drives the encoder and the
        # damage ledger under the sanitiser; see Tests/Support/asan_runner.c.
        if known.sanitize == "address":
            return native_sanitizer_run(SANITIZERS["address"])
        # Undefined-behaviour reaches every fuzzed input when the ctypes suite can host
        # it, which is worth more than the native runner's fixed inputs -- so try that
        # first. It only works where the interpreter is allowed to load a sanitizer
        # runtime at all: a venv built on Apple's signed python3 is not, and the dlopen
        # fails with "Sanitizer load violates platform policy" before a single test runs.
        # Falling back to the native runner there keeps the command meaning the same
        # thing on a laptop and on CI, instead of being red on one and green on the other.
        flags = SANITIZERS[known.sanitize]
        products = build("Debug", flags)
        library = products / "libMViewCore.dylib"
        probe = subprocess.run([str(python), "-c", f"import ctypes; ctypes.CDLL({str(library)!r})"],
                               capture_output=True, text=True)
        if probe.returncode != 0:
            detail = next((line.strip() for line in probe.stderr.splitlines()
                           if "policy" in line or "Library not loaded" in line), "dlopen failed")
            print(f"this interpreter cannot load a {known.sanitize}-sanitised library: "
                  f"{detail[:160]}")
            print("falling back to the native runner, which covers the pure-logic sources only")
            return native_sanitizer_run(flags)
        print(f"running the suite against a {known.sanitize}-sanitised library")
        return run_pytest(python, passthrough, {"MVIEW_DYLIB": str(library)})

    build(known.configuration)
    return run_pytest(python, passthrough)


if __name__ == "__main__":
    sys.exit(main())
