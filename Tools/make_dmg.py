#!/usr/bin/env python3
"""Package a built variant as a distributable .dmg.

    python3 Tools/make_dmg.py                 both disk images
    python3 Tools/make_dmg.py production      just the installable app
    python3 Tools/make_dmg.py debug-verbose   just the portable diagnostic build

The production image is the familiar drag-to-Applications layout. The debug image carries the
portable binary instead, because that build is deliberately never installed: it owns the dock
only while it is running and leaves nothing behind.

Images are UDZO (compressed, read-only). Local builds remain ad-hoc signed; the release
workflow signs and notarizes the app and disk image before publication.
"""
import argparse
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
VERSION = (ROOT / "VERSION").read_text().strip()   # overridden by --version

README = """Oizys {version}

An open-source driver for DisplayLink Ridge docks on macOS.

Install
  Drag Oizys.app to Applications, then launch it once so macOS can ask for
  Screen Recording. Oizys captures the desktop to send it over USB, so it
  cannot drive a panel without that permission.

Command line and terminal UI
  The CLI is inside Oizys.app/Contents/MacOS/OizysDriver. A drag install does
  not add a shell command or login agent. The app can enable login startup.

{signing_note}
"""

LOCAL_SIGNING_NOTE = """This local build is signed ad hoc. Build a Developer ID signed and
notarized release for use on another Mac."""

DEBUG_README = """Oizys {version} — portable diagnostic build

This binary is deliberately not installable. Run it from wherever you put it:

  ./Oizys-debug tui                        full-screen terminal UI
  ./Oizys-debug probe                      identify the dock, read-only
  ./Oizys-debug patterns --takeover --seconds 90
                                           colour patterns on both heads
  ./Oizys-debug run --takeover --stats     forward the live desktop

It claims the dock only while it runs and leaves nothing behind. Commands that
take the dock need the vendor software stopped; `--takeover` does that.

{diagnostics_note}
"""


def variant_payload(variant, staging, version, distribution=False):
    """Copy what the image should contain into `staging`; return the volume name."""
    if variant.startswith("production"):
        app = ROOT / "build" / "apps" / variant / version / "Oizys.app"
        if not app.is_dir():
            raise SystemExit(f"Build it first: OIZYS_VARIANT={variant} ./dev.sh build")
        subprocess.run(["ditto", str(app), str(staging / "Oizys.app")], check=True)
        (staging / "Applications").symlink_to("/Applications")
        (staging / "README.txt").write_text(README.format(
            version=version, signing_note="" if distribution else LOCAL_SIGNING_NOTE))
        return f"Oizys {version}" + (" fallback" if variant == "production-fallback" else "")

    binary = ROOT / "dist" / f"Oizys-debug-{version}-{variant}"
    if not binary.is_file():
        raise SystemExit(f"Build it first: OIZYS_VARIANT={variant} ./dev.sh build")
    target = staging / "Oizys-debug"
    shutil.copy2(binary, target)
    target.chmod(0o755)
    note = ("Verbose diagnostics are compiled in, including the dock's firmware trace."
            if variant != "debug-minimal" else "Minimal diagnostics are compiled in.")
    (staging / "README.txt").write_text(DEBUG_README.format(version=version, diagnostics_note=note))
    return f"Oizys {version} {variant}"


def build(variant, output_dir, version, distribution=False):
    name = {"production": f"Oizys-{version}",
            "production-fallback": f"Oizys-{version}-production-fallback",
            "debug-verbose": f"Oizys-debug-{version}"}.get(
                variant, f"Oizys-debug-{version}-{variant}")
    output = output_dir / f"{name}.dmg"
    output.unlink(missing_ok=True)
    with tempfile.TemporaryDirectory(prefix="oizys-dmg-") as temporary:
        staging = Path(temporary) / "payload"
        staging.mkdir()
        volume = variant_payload(variant, staging, version, distribution)
        subprocess.run(
            ["hdiutil", "create", "-volname", volume, "-srcfolder", str(staging),
             "-fs", "HFS+", "-format", "UDZO", "-imagekey", "zlib-level=9",
             "-quiet", str(output)],
            check=True)
    return output


def main():
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    # argparse checks a list default against `choices` and rejects it, so validate by hand.
    parser.add_argument("variants", nargs="*", metavar="{production,debug-verbose}",
                        help="which images to build (default: both)")
    parser.add_argument("--output", default=str(ROOT / "dist"),
                        help="directory to write the images into")
    parser.add_argument("--version", default=VERSION,
                        help="version to package; defaults to the VERSION file")
    parser.add_argument("--distribution", action="store_true",
                        help="omit the local ad-hoc signing notice from a Developer ID release")
    arguments = parser.parse_args()
    known = ["production", "production-fallback", "debug-minimal", "debug-verbose", "debug-fallback"]
    for variant in arguments.variants:
        if variant not in known:
            parser.error(f"invalid choice: {variant!r} (choose from {', '.join(known)})")
    output_dir = Path(arguments.output)
    output_dir.mkdir(parents=True, exist_ok=True)

    for variant in (arguments.variants or ("production", "debug-verbose")):
        image = build(variant, output_dir, arguments.version, arguments.distribution)
        size = image.stat().st_size / (1024 * 1024)
        print(f"{image}  ({size:.1f} MB)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
