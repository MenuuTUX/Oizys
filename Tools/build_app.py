#!/usr/bin/env python3
"""Build a local Swift menu-bar app containing the C driver. Does not install or launch it."""
import argparse
import pathlib
import plistlib
import shutil
import subprocess

ROOT = pathlib.Path(__file__).resolve().parent.parent


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--skip-driver-build", action="store_true")
    args = parser.parse_args()
    if not args.skip_driver_build:
        subprocess.run(["xcodebuild", "-project", "MView.xcodeproj", "-scheme", "mview",
                        "-configuration", "Release", "build"], cwd=ROOT, check=True)
    bundle = ROOT / "build/Release/MView.app"
    contents = bundle / "Contents"
    binaries = contents / "MacOS"
    binaries.mkdir(parents=True, exist_ok=True)
    subprocess.run([
        "xcrun", "swiftc", "-O", "-swift-version", "5", "-target", "arm64-apple-macosx14.0",
        "-module-cache-path", str(ROOT / "build/ModuleCache"),
        str(ROOT / "Sources/MViewApp/Main.swift"), "-o", str(binaries / "MView"),
    ], check=True)
    # MView and mview are the same filename on the default macOS filesystem.
    # Keep the Swift app and C helper distinct even on case-insensitive volumes.
    shutil.copy2(ROOT / "build/Release/mview", binaries / "MViewDriver")
    if (binaries / "MView").samefile(binaries / "MViewDriver"):
        raise RuntimeError("Swift app and C driver resolved to the same executable")
    if (binaries / "MView").read_bytes() == (binaries / "MViewDriver").read_bytes():
        raise RuntimeError("C driver overwrote the Swift app executable")
    info = {
        "CFBundleIdentifier": "org.mview.MView",
        "CFBundleName": "MView",
        "CFBundleDisplayName": "MView",
        "CFBundleExecutable": "MView",
        "CFBundlePackageType": "APPL",
        "CFBundleShortVersionString": "0.1.0",
        "CFBundleVersion": "1",
        "LSMinimumSystemVersion": "14.0",
        "LSUIElement": True,
        "NSHighResolutionCapable": True,
    }
    (contents / "Info.plist").write_bytes(plistlib.dumps(info))
    subprocess.run(["codesign", "--force", "--sign", "-", "--options", "runtime", str(bundle)],
                   check=True)
    subprocess.run(["codesign", "--verify", "--strict", str(bundle)], check=True)
    print(bundle)
    print("Local ad-hoc build: privacy permission may need renewal after rebuilding.")


if __name__ == "__main__":
    main()
