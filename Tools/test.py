#!/usr/bin/env python3
"""Build the library and run the suite.

    python3 Tools/test.py                 build, then run every suite
    python3 Tools/test.py -k damage       pass through to pytest
    python3 Tools/test.py --sanitize address
    python3 Tools/test.py --coverage [--coverage-floor 80]
    python3 Tools/test.py --mutate

The tests drive libOizysCore.dylib through ctypes, so a sanitiser run means building the
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
PROJECT = ROOT / "Oizys.xcodeproj"

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
    command = ["xcodebuild", "-project", str(PROJECT), "-target", "OizysCoreDylib",
               "-configuration", configuration, "build"]
    if extra_cflags:
        command.append(f"OTHER_CFLAGS=$(inherited) {extra_cflags}")
        command.append(f"OTHER_LDFLAGS=$(inherited) {extra_ldflags or extra_cflags}")
    result = subprocess.run(command, capture_output=True, text=True, cwd=ROOT)
    if result.returncode != 0:
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
    runner = ["-m", "pytest"]
    if env.get("OIZYS_COVERAGE_DIR"):
        runner = ["-m", "coverage", "run", "--branch", "--source=Tools", "-m", "pytest"]
    return subprocess.run([str(python), *runner, "Tests", "-q", *extra_args],
                          cwd=ROOT, env=env).returncode


def coverage(python, passthrough, floor, project_floor=0):
    """Measure native products, native test adapters, and all Python tools separately."""
    if subprocess.run([str(python), "-c", "import coverage"], capture_output=True).returncode:
        subprocess.run([str(python), "-m", "pip", "install", "coverage>=7,<8"], check=True)
    raw = ROOT / "build/coverage"
    shutil.rmtree(raw, ignore_errors=True)
    raw.mkdir(parents=True)
    environment = dict(os.environ, LLVM_PROFILE_FILE=str(raw / "%m-%p.profraw"),
                       OIZYS_COVERAGE_DIR=str(raw), COVERAGE_FILE=str(raw / ".coverage"))
    flags = "-fprofile-instr-generate -fcoverage-mapping"
    # Separate products keep instrumented builds away from installed/running apps.
    common = ["xcodebuild", "-project", str(PROJECT), "build",
              f"SYMROOT={raw / 'products'}", f"OBJROOT={raw / 'intermediates'}",
              f"OTHER_CFLAGS=$(inherited) {flags}",
              "OTHER_SWIFT_FLAGS=$(inherited) -profile-generate -profile-coverage-mapping",
              "OTHER_LDFLAGS=$(inherited) -fprofile-instr-generate",
              "GCC_OPTIMIZATION_LEVEL=0", "SWIFT_OPTIMIZATION_LEVEL=-Onone",
              "LLVM_LTO=NO", "DEAD_CODE_STRIPPING=NO"]
    objects = []
    for configuration, target in (("Debug", "OizysCoreDylib"),
                                  ("DebugVerbose", "OizysApp"), ("Production", "OizysApp")):
        with (raw / f"build-{configuration}.log").open("w") as log:
            subprocess.run([*common, "-configuration", configuration, "-target", target],
                           cwd=ROOT, env=environment, stdout=log, stderr=subprocess.STDOUT, check=True)
        products = raw / "products" / configuration
        if target == "OizysCoreDylib":
            library = products / "libOizysCore.dylib"
            objects.append(library)
        else:
            name = "Oizys" if configuration == "Production" else "Oizys-debug"
            objects += [products / "oizys", products / f"{name}.app/Contents/MacOS/{name}"]
    # Developer executables count even when no automated test enters them.
    for name in ("MotionBench", "FixtureBench"):
        binary = raw / name
        subprocess.run(["xcrun", "swiftc", "-D", "OIZYS_FIXTURE_DEBUG",
                        "-profile-generate", "-profile-coverage-mapping",
                        "-module-cache-path", str(ROOT / "build/ModuleCache"),
                        str(ROOT / f"Tools/{name}.swift"), "-o", str(binary)], check=True)
        objects.append(binary)
    binary = raw / "PortableDebug"
    subprocess.run(["xcrun", "clang", "-fobjc-arc", *flags.split(),
                    "-framework", "Foundation", "-framework", "AppKit",
                    str(ROOT / "Tools/PortableDebug.m"), "-o", str(binary)], check=True)
    objects.append(binary)
    # Packaging invokes build-info; those counters are not test coverage.
    for profile in raw.glob("*.profraw"):
        profile.unlink()
    environment["OIZYS_DYLIB"] = str(library)
    code = run_pytest(python, passthrough, environment)
    if code:
        print(f"Test suite failed ({code}); refusing to publish partial coverage as a passing run.")
        return code
    profiles = sorted(raw.glob("*.profraw"))
    if not profiles:
        raise RuntimeError("No native coverage profiles were written")
    registry = raw / "objects.txt"
    if registry.exists():
        objects += [pathlib.Path(p) for p in registry.read_text().splitlines()]
    merged = raw / "merged.profdata"
    subprocess.run(["xcrun", "llvm-profdata", "merge", "-sparse", *map(str, profiles),
                    "-o", str(merged)], check=True)
    sources = sorted(p for folder in (ROOT / "Sources", ROOT / "Tools") for p in folder.rglob("*")
                     if p.suffix in (".c", ".swift", ".m"))
    arguments = [str(objects[0]), *[f"-object={p}" for p in objects[1:]],
                 f"-instr-profile={merged}", *map(str, sources)]
    native = json.loads(subprocess.check_output(
        ["xcrun", "llvm-cov", "export", "--summary-only", *arguments], text=True))["data"][0]
    # Distinct executables can have functions called main with different hashes.
    # llvm-cov omits mismatched records. Its empty baseline keeps those unexecuted
    # functions in our denominator instead of silently inflating coverage.
    baseline = json.loads(subprocess.check_output(
        ["xcrun", "llvm-cov", "export", "--summary-only", "--empty-profile",
         *[a for a in arguments if not a.startswith("-instr-profile=")]], text=True))["data"][0]
    actual = {f["filename"]: f for f in native["files"]}
    for file in baseline["files"]:
        measured_file = actual.get(file["filename"])
        for kind, value in file["summary"].items():
            value["covered"] = measured_file["summary"][kind]["covered"] if measured_file else 0
            value["percent"] = 100 * value["covered"] / value["count"] if value["count"] else 0
    native["files"] = baseline["files"]
    for kind, value in native["totals"].items():
        value["count"] = baseline["totals"][kind]["count"]
        value["percent"] = 100 * value["covered"] / value["count"] if value["count"] else 0
    subprocess.run(["xcrun", "llvm-cov", "report", *arguments], check=True)
    subprocess.run(["xcrun", "llvm-cov", "show", *arguments, "-format=html",
                    f"-output-dir={raw / 'html'}"], check=True, stdout=subprocess.DEVNULL)
    subprocess.run([str(python), "-m", "coverage", "json", "-o", str(raw / "python.json")],
                   cwd=ROOT, env=environment, check=True)
    subprocess.run([str(python), "-m", "coverage", "html", "-d", str(raw / "python-html")],
                   cwd=ROOT, env=environment, check=True)
    python_report = json.loads((raw / "python.json").read_text())
    reached = {"wht.c", "encode.c", "dl3.c", "crypto.c", "profile.c", "config.c"}
    reachable = [f["summary"]["lines"] for f in native["files"]
                 if pathlib.Path(f["filename"]).name in reached]
    covered = sum(f["covered"] for f in reachable)
    count = sum(f["count"] for f in reachable)
    percent = 100 * covered / count if count else 0
    measured = {pathlib.Path(f["filename"]).resolve() for f in native["files"]}
    unmeasured = [str(p.relative_to(ROOT)) for p in sources if p.resolve() not in measured]
    # llvm-cov/coverage.py do not instrument the shell entry point. Never hide it.
    unmeasured.append("dev.sh")
    py = python_report["totals"]
    native_lines = native["totals"]["lines"]
    total = native_lines["count"] + py["num_statements"]
    hit = native_lines["covered"] + py["covered_lines"]
    combined = 100 * hit / total if total else 0
    summary = {"native": native, "python": py, "unmeasured": unmeasured,
               "reachable_lines": {"covered": covered, "count": count, "percent": percent},
               "measured_lines": {"covered": hit, "count": total, "percent": combined},
               "project_complete": False}
    (raw / "summary.json").write_text(json.dumps(summary, indent=2) + "\n")
    print(f"\nReachable core line coverage: {percent:.2f}% ({covered}/{count}); floor {floor:.2f}%")
    print(f"All measured native/Python lines, including baseline-only functions: {combined:.2f}% ({hit}/{total})")
    print("Not instrumented: " + ", ".join(unmeasured))
    print(f"Reports: {raw / 'html/index.html'} and {raw / 'python-html/index.html'}")
    if percent < floor or combined < project_floor or (project_floor == 100 and unmeasured):
        print("Coverage requirement not met. Unexecuted and unmeasured code remains in the report.")
        return 1
    return 0


def native_sanitizer_run(flags):
    """Compile Tests/Support/asan_runner.c with the pure-logic sources under the sanitiser
    and run it directly. Our own binary, so the sanitizer loads with no platform policy in
    the way -- unlike injecting it into the Apple-signed Python host."""
    pure = ["config.c", "encode.c", "wht.c", "crypto.c", "dl3.c", "profile.c", "log.c"]
    sources = [str(ROOT / "Sources/OizysCore" / name) for name in pure]
    binary = ROOT / "build" / "asan_runner"
    binary.parent.mkdir(parents=True, exist_ok=True)
    command = ["xcrun", "clang", "-std=c11", "-fblocks", "-g", "-O1",
               "-mcpu=apple-m1", "-DOIZYS_LOG_IMPLEMENTATION",
               "-I", str(ROOT / "Sources/OizysCore/include"),
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
    if sys.argv[1:2] == ["--fixture"]:
        from fixture import main as fixture_main
        return fixture_main(sys.argv[2:])
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--sanitize", choices=sorted(SANITIZERS))
    parser.add_argument("--coverage", action="store_true")
    parser.add_argument("--coverage-floor", type=float, default=80.0,
                        metavar="PERCENT",
                        help="fail if reachable line coverage falls below this")
    parser.add_argument("--project-coverage-floor", type=float, default=0, metavar="PERCENT",
                        help="minimum combined measured native/Python lines; 100 also rejects unmeasured files")
    parser.add_argument("--mutate", action="store_true")
    parser.add_argument("--configuration", default="Release")
    known, passthrough = parser.parse_known_args()

    if not all(0 <= value <= 100 for value in (known.coverage_floor, known.project_coverage_floor)):
        parser.error("coverage floors must be between 0 and 100")
    python = ensure_venv()

    if known.mutate:
        return subprocess.run([str(python), str(ROOT / "Tools" / "mutate.py"),
                               *passthrough], cwd=ROOT).returncode
    if known.coverage:
        return coverage(python, passthrough, known.coverage_floor, known.project_coverage_floor)
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
        library = products / "libOizysCore.dylib"
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
        return run_pytest(python, passthrough, {"OIZYS_DYLIB": str(library)})

    products = build(known.configuration)
    return run_pytest(python, passthrough, {"OIZYS_DYLIB": str(products / "libOizysCore.dylib")})


if __name__ == "__main__":
    sys.exit(main())
