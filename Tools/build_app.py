#!/usr/bin/env python3
"""Build native Xcode products; distribute debug as one executable, production as an app."""
import argparse
import json
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import tempfile

from debug_session import stop_debug

ROOT = Path(__file__).resolve().parent.parent
VARIANTS = {
    "debug-minimal": ("DebugMinimal", True, False, False),
    "debug-verbose": ("DebugVerbose", True, True, False),
    "debug-fallback": ("DebugFallback", True, True, True),
    "production": ("Production", False, False, False),
    "production-fallback": ("ProductionFallback", False, False, True),
}


def sign(path, identity, entitlements=None):
    command = ["codesign", "--force", "--sign", identity, "--options", "runtime"]
    if identity != "-": command += ["--timestamp"]
    if entitlements: command += ["--entitlements", str(entitlements)]
    subprocess.run([*command, str(path)], check=True)


def portable_debug(bundle, destination, identity):
    with tempfile.TemporaryDirectory(prefix="oizys-portable-") as temporary:
        temporary = Path(temporary)
        # One stable bundle name inside the executable; the display name carries its version.
        stage = temporary / "Oizys-debug.app"
        shutil.copytree(bundle, stage)
        archive = temporary / "payload.zip"
        subprocess.run(["ditto", "-c", "-k", "--keepParent", str(stage), str(archive)], check=True)
        subprocess.run(["xcrun", "clang", "-O2", "-fobjc-arc", "-arch", "arm64", "-mmacosx-version-min=14.0",
                        "-framework", "Foundation", "-framework", "AppKit", str(ROOT / "Tools/PortableDebug.m"),
                        "-Wl,-sectcreate,__DATA,__oizys," + str(archive), "-o", str(destination)], check=True)
        sign(destination, identity)
        subprocess.run(["codesign", "--verify", "--strict", str(destination)], check=True)
    print(destination)


def build(variant, identity="-", version=None, skip=False, coverage=False, output_format=None, restart_debug=False):
    version = version or (ROOT / "VERSION").read_text().strip()
    if not re.fullmatch(r"\d+(?:\.\d+){0,2}", version):
        raise ValueError("Version must have one to three numeric components")
    configuration, debug, verbose, fallback = VARIANTS[variant]
    output_format = output_format or ("portable" if debug else "app")
    if debug and output_format != "portable":
        raise ValueError("Debug distribution is a portable executable only; use --format portable (the default).")
    if restart_debug:
        stop_debug(ROOT, variant)
    subprocess.run(["python3", str(ROOT / "Tools/make_xcodeproj.py")], check=True)
    product = ROOT / "build" / configuration / ("Oizys-debug.app" if debug else "Oizys.app")
    running = subprocess.check_output(["ps", "-axo", "comm="], text=True)
    if str(product / "Contents/MacOS/").casefold() in running.casefold():
        raise RuntimeError("Quit the Xcode app before rebuilding its bundle")
    if not skip:
        command = ["xcodebuild", "-project", "Oizys.xcodeproj", "-scheme", "Oizys-debug" if debug else "Oizys-production",
                   "-configuration", configuration, "build", f"MARKETING_VERSION={version}",
                   f"CURRENT_PROJECT_VERSION={version}", f"CODE_SIGN_IDENTITY={identity}"]
        if coverage: command += ["CLANG_ENABLE_CODE_COVERAGE=YES"]
        subprocess.run(command, cwd=ROOT, check=True)
    policy = json.loads((product / "Contents/Resources/build-info.json").read_text())
    expected = dict(product="Oizys", diagnostics=debug, verbose=verbose, displaylink_fallback=fallback)
    if policy != expected: raise RuntimeError(f"Driver build policy mismatch: {policy} != {expected}")
    metadata = plistlib.loads((product / "Contents/Info.plist").read_bytes())
    if metadata["CFBundleShortVersionString"] != version:
        raise RuntimeError("Rebuild the Xcode app for the requested version")
    bundle = ROOT / "build/apps" / variant / version / product.name
    if str(bundle / "Contents/MacOS/").casefold() in running.casefold():
        raise RuntimeError("Quit this app before replacing its build output")
    if bundle.exists(): shutil.rmtree(bundle)
    shutil.copytree(product, bundle)
    # Preserve symbols alongside distributables for LLDB and Instruments.
    symbols = product.with_suffix(".app.dSYM")
    if symbols.exists():
        target = bundle.with_suffix(".app.dSYM")
        if target.exists(): shutil.rmtree(target)
        shutil.copytree(symbols, target)
    subprocess.run(["codesign", "--verify", "--deep", "--strict", str(bundle)], check=True)
    print(bundle)
    destination = ROOT / "dist"
    destination.mkdir(exist_ok=True)
    stem = f"{'Oizys-debug' if debug else 'Oizys'}-{version}-{variant}"
    if debug:
        executable = destination / stem
        portable_debug(bundle, executable, identity)
        return executable
    if output_format in ("portable", "both"):
        archive = destination / (stem + ".zip")
        subprocess.run(["ditto", "-c", "-k", "--keepParent", str(bundle), str(archive)], check=True)
        print(archive)
    if output_format in ("installer", "both"):
        package = destination / (stem + ".pkg")
        with tempfile.TemporaryDirectory(prefix="oizys-package-") as temporary:
            stage = Path(temporary) / "root"; stage.mkdir()
            shutil.copytree(bundle, stage / bundle.name)
            components = Path(temporary) / "components.plist"
            components.write_bytes(plistlib.dumps([{
                "RootRelativeBundlePath": bundle.name, "BundleIsRelocatable": False,
                "BundleHasStrictIdentifier": False, "BundleIsVersionChecked": True,
                "BundleOverwriteAction": "upgrade",
            }]))
            subprocess.run(["pkgbuild", "--root", str(stage), "--install-location", "/Applications",
                            "--component-plist", str(components), "--identifier", "org.oizys.Oizys.installer",
                            "--version", version, str(package)], check=True)
        print(package)
    if identity == "-": print("Local ad-hoc signature. Public distribution still requires Developer ID signing and notarization.")
    return bundle


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--variant", choices=VARIANTS, default="debug-minimal")
    parser.add_argument("--skip-build", "--skip-driver-build", dest="skip", action="store_true",
                        help="Package an already built native app")
    parser.add_argument("--sign", default="-")
    parser.add_argument("--version")
    parser.add_argument("--format", dest="output_format", choices=("app", "portable", "installer", "both"))
    parser.add_argument("--coverage", action="store_true")
    parser.add_argument("--restart-debug", action="store_true",
                        help="Close the previous selected debug session before rebuilding; never stop production")
    args = parser.parse_args()
    try:
        build(args.variant, args.sign, args.version, args.skip, args.coverage, args.output_format, args.restart_debug)
    except (RuntimeError, ValueError, subprocess.SubprocessError) as error:
        parser.exit(1, f"Build failed: {error}\n")
