#!/usr/bin/env python3
"""Assemble resources for the native Xcode app target. Never install or launch it."""
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import zipfile

ROOT = Path(__file__).resolve().parent.parent


def package(bundle, driver, debug, identity="-", allow_debugger=False):
    contents = bundle / "Contents"
    binaries = contents / "MacOS"
    resources = contents / "Resources"
    binaries.mkdir(parents=True, exist_ok=True)
    resources.mkdir(parents=True, exist_ok=True)
    shutil.copy2(driver, binaries / "OizysDriver")
    info = json.loads(subprocess.check_output([str(driver), "build-info"]))
    if info["diagnostics"] != debug:
        raise RuntimeError("App and driver diagnostic policies differ")
    (resources / "build-info.json").write_text(json.dumps(info, indent=2) + "\n")
    if debug:
        digest = hashlib.sha256()
        with zipfile.ZipFile(resources / "Developer.zip", "w", zipfile.ZIP_DEFLATED) as output:
            paths = [ROOT / "VERSION", ROOT / "dev.sh"]
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
