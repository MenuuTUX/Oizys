#!/usr/bin/env python3
"""Build the library and run the suite.

    python3 Tools/test.py                 build, then run every suite
    python3 Tools/test.py -k damage       pass through to pytest
    python3 Tools/test.py --sanitize address
    python3 Tools/test.py --coverage
    python3 Tools/test.py --mutate

The tests drive libMViewCore.dylib through ctypes, so a sanitiser run means building the
library with the sanitiser and letting the same Python suite drive it. Nothing about the
tests changes.
"""
from __future__ import annotations

import argparse
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


def coverage(python, passthrough):
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
    # Only the files a test can reach without the dock plugged in. driver.c, usb_probe.c
    # and the Objective-C transport need real hardware; reporting them as 0% would bury
    # the number that means something.
    testable = ["wht.c", "encode.c", "dl3.c", "crypto.c", "profile.c"]
    sources = [str(ROOT / "Sources" / "MViewCore" / name) for name in testable]
    subprocess.run(["xcrun", "llvm-cov", "report", str(library),
                    f"-instr-profile={merged}", *sources], cwd=ROOT)
    subprocess.run(["xcrun", "llvm-cov", "show", str(library), f"-instr-profile={merged}",
                    "-format=html", f"-output-dir={raw / 'html'}", *sources],
                   cwd=ROOT, capture_output=True)
    print(f"\nhtml report: {(raw / 'html' / 'index.html').relative_to(ROOT)}")
    return code


def main():
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--sanitize", choices=sorted(SANITIZERS))
    parser.add_argument("--coverage", action="store_true")
    parser.add_argument("--mutate", action="store_true")
    parser.add_argument("--configuration", default="Release")
    known, passthrough = parser.parse_known_args()

    python = ensure_venv()

    if known.mutate:
        return subprocess.run([str(python), str(ROOT / "Tools" / "mutate.py"),
                               *passthrough], cwd=ROOT).returncode
    if known.coverage:
        return coverage(python, passthrough)
    if known.sanitize:
        flags = SANITIZERS[known.sanitize]
        products = build("Debug", flags)
        print(f"running the suite against a {known.sanitize}-sanitised library")
        env = {"MVIEW_DYLIB": str(products / "libMViewCore.dylib")}
        # ASan has to be first in the load order, so the interposed allocator is in place
        # before anything else runs.
        if known.sanitize == "address":
            runtime = subprocess.run(
                ["xcrun", "--find", "clang"], capture_output=True, text=True).stdout.strip()
            lib = (pathlib.Path(runtime).parents[1] / "lib" / "clang").glob(
                "*/lib/darwin/libclang_rt.asan_osx_dynamic.dylib")
            found = next(iter(sorted(lib)), None)
            if found:
                env["DYLD_INSERT_LIBRARIES"] = str(found)
        return run_pytest(python, passthrough, env)

    build(known.configuration)
    return run_pytest(python, passthrough)


if __name__ == "__main__":
    sys.exit(main())
