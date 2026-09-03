#!/usr/bin/env python3
"""Assemble resources for the native Xcode app target. Never install or launch it."""
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import zipfile

ROOT = Path(__file__).resolve().parent.parent


def app_icon(destination):
    """Build the standard macOS sizes from the app's mark."""
    with tempfile.TemporaryDirectory(prefix="oizys-icon-") as temporary:
        iconset = Path(temporary) / "Oizys.iconset"
        iconset.mkdir()
        for size in (16, 32, 128, 256, 512):
            for scale in (1, 2):
                name = f"icon_{size}x{size}{'@2x' if scale == 2 else ''}.png"
                subprocess.run(["sips", "-z", str(size * scale), str(size * scale),
                                str(ROOT / "Assets/Logo.png"), "--out", str(iconset / name)],
                               check=True, stdout=subprocess.DEVNULL)
        subprocess.run(["iconutil", "-c", "icns", str(iconset), "-o", str(destination)], check=True)


def package(bundle, driver, debug, identity="-", allow_debugger=False):
    contents = bundle / "Contents"
    binaries = contents / "MacOS"
    resources = contents / "Resources"
    binaries.mkdir(parents=True, exist_ok=True)
    resources.mkdir(parents=True, exist_ok=True)
    app_icon(resources / "Oizys.icns")
    # Both pictures ship. The menu-bar item derives its template from full-resolution
    # artwork rather than from the icns: the stipple has to be thresholded at 18 points, and
    # a source that sips has already resampled down to 16px has none left to threshold.
    # Bundled under the same names they have in Assets/, so a resource lookup and a
    # glance at the repository agree about which picture is which.
    artwork = {"Logo.png", "tiny_Logo.png"}
    shutil.copy2(ROOT / "Assets/Logo.png", resources / "Logo.png")
    shutil.copy2(ROOT / "Assets/tiny_Logo.png", resources / "tiny_Logo.png")
    # Resources is reused between builds, so a picture that has been renamed or dropped stays
    # in the bundle and ships forever. Packaging owns every PNG in here; anything else is left
    # over from a previous name for one of these two.
    for stale in resources.glob("*.png"):
        if stale.name not in artwork:
            stale.unlink()
    shutil.copy2(driver, binaries / "OizysDriver")
    info = json.loads(subprocess.check_output([str(driver), "build-info"]))
    if info["diagnostics"] != debug:
        raise RuntimeError("App and driver diagnostic policies differ")
    (resources / "build-info.json").write_text(json.dumps(info, indent=2) + "\n")
    if debug:
        digest = hashlib.sha256()
        with zipfile.ZipFile(resources / "Developer.zip", "w", zipfile.ZIP_DEFLATED) as output:
            paths = [ROOT / name for name in ("VERSION", "dev.sh", "Assets/Logo.png", "Assets/tiny_Logo.png", "README.md",
                                              "CONTRIBUTING.md", "CHANGELOG.md")]
            for directory in ("Sources", "Tools", "Tests", "Configs", "Oizys.xcodeproj"):
                paths += sorted((ROOT / directory).rglob("*"))
            for path in paths:
                if not path.is_file() or path.is_symlink(): continue
                if any(part in ("__pycache__", "xcuserdata", "project.xcworkspace") for part in path.parts): continue
                if path.name.startswith("fixture.json") or path.suffix in (".pyc", ".DS_Store"): continue
                relative = path.relative_to(ROOT).as_posix()
                data = path.read_bytes()
                output.writestr(relative, data)
                digest.update(relative.encode() + b"\0" + data)
        (resources / "developer-revision.txt").write_text(digest.hexdigest()[:16] + "\n")
        subprocess.run(["xcrun", "swiftc", "-O", "-g", "-module-cache-path", str(ROOT / "build/ModuleCache"),
                        "-target", "arm64-apple-macosx14.0", str(ROOT / "Tools/MotionBench.swift"),
                        "-o", str(binaries / "OizysMotionBench")], check=True)
    else:
        for path in (resources / "Developer.zip", resources / "developer-revision.txt", binaries / "OizysMotionBench"):
            path.unlink(missing_ok=True)
    # Xcode signs the outer app after this phase. Sign nested executables first.
    for name in ("OizysDriver", "OizysMotionBench") if debug else ("OizysDriver",):
        command = ["codesign", "--force", "--sign", identity or "-", "--options", "runtime"]
        if debug or allow_debugger: command += ["--entitlements", str(ROOT / "Configs/Debug.entitlements")]
        subprocess.run([*command, str(binaries / name)], check=True)


if __name__ == "__main__":
    package(Path(os.environ["TARGET_BUILD_DIR"]) / os.environ["FULL_PRODUCT_NAME"],
            Path(os.environ["BUILT_PRODUCTS_DIR"]) / "oizys",
            not os.environ["CONFIGURATION"].startswith("Production"),
            os.environ.get("EXPANDED_CODE_SIGN_IDENTITY", "-"), os.environ["CONFIGURATION"].endswith("Profile"))
