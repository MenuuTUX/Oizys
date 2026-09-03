"""Prepare a fresh clone: developer tools, Python environment, Xcode project.

Runs no tests, builds nothing, launches no browser and changes no privacy settings.
Safe to re-run; every step is skipped when it is already satisfied.
"""
from pathlib import Path
import argparse
import shutil
import subprocess
import sys

ROOT = Path(__file__).resolve().parent.parent
VENV = ROOT / ".venv"
PYTHON = VENV / "bin/python"
PACKAGES = ("pytest", "hypothesis", "numpy")
# Only the optional fixture benchmark needs these, and only when it is pointed at a
# public video source. Nothing else in the repository imports them.
BREW_TOOLS = {"obscura": "obscura", "yt-dlp": "yt-dlp"}


def run(command, **kwargs):
    print("+", " ".join(str(part) for part in command), flush=True)
    return subprocess.run(command, **kwargs)


def xcode():
    """(ok, message). Installing Xcode needs the user's own App Store session."""
    if not shutil.which("xcodebuild"):
        return False, ("Xcode is missing. Install it from the App Store, then run:\n"
                       "    sudo xcode-select --switch /Applications/Xcode.app/Contents/Developer")
    probe = subprocess.run(["xcodebuild", "-version"], capture_output=True, text=True)
    if probe.returncode:
        return False, ("xcodebuild is present but not usable, which usually means the command line\n"
                       "tools are selected instead of Xcode. Run:\n"
                       "    sudo xcode-select --switch /Applications/Xcode.app/Contents/Developer")
    return True, probe.stdout.strip().splitlines()[0]


def report():
    ok, detail = xcode()
    lines = [f"Xcode: {detail}" if ok else f"Xcode: MISSING\n{detail}",
             f"Python venv: {'ready' if PYTHON.exists() else 'not created'} ({VENV})"]
    for tool in BREW_TOOLS:
        found = shutil.which(tool)
        lines.append(f"{tool}: {found or 'not installed (optional; fixture benchmark only)'}")
    return ok, "\n".join(lines)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true", help="report what is missing and install nothing")
    parser.add_argument("--no-optional", action="store_true", help="skip the optional fixture-benchmark tools")
    options = parser.parse_args()

    ok, summary = report()
    print(summary, flush=True)
    if options.check:
        return 0 if ok else 1
    if not ok:
        print("\nInstall Xcode first; nothing else was changed.", file=sys.stderr)
        return 1

    if not PYTHON.exists():
        run([sys.executable, "-m", "venv", str(VENV)], check=True)
    run([str(PYTHON), "-m", "pip", "install", "--disable-pip-version-check", *PACKAGES], check=True)

    if not options.no_optional:
        missing = [formula for tool, formula in BREW_TOOLS.items() if not shutil.which(tool)]
        if not missing:
            pass
        elif shutil.which("brew"):
            # Optional: a failure here leaves a working checkout, so it does not stop setup.
            if run(["brew", "install", *missing]).returncode:
                print(f"Could not install {', '.join(missing)}. Everything except the fixture "
                      "benchmark still works.", file=sys.stderr)
        else:
            print(f"Homebrew is not installed, so {', '.join(missing)} were skipped. They are only "
                  "needed for the optional fixture benchmark.", file=sys.stderr)

    run([str(PYTHON), str(ROOT / "Tools/make_xcodeproj.py")], check=True)
    print("\nReady. Next:\n"
          "    ./dev.sh install production   # build and install the app and CLI\n"
          "    ./dev.sh debug debug-verbose  # portable developer build, installs nothing\n"
          "    ./dev.sh test                 # software tests; no hardware required")
    return 0


def demo():
    ok, summary = report()
    assert isinstance(ok, bool) and "Xcode:" in summary and "Python venv:" in summary
    assert all(tool in summary for tool in BREW_TOOLS)
    print("setup self-check passed\n" + summary)


if __name__ == "__main__":
    sys.exit(demo() if "--self-check" in sys.argv else main())
