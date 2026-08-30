#!/usr/bin/env python3
"""Build a named Mview app variant. No installation, takeover or publication."""
import argparse
import json
import pathlib
import plistlib
import shutil
import subprocess

ROOT = pathlib.Path(__file__).resolve().parent.parent
VARIANTS = {
    "debug-minimal": ("DebugMinimal", True, False, False),
    "debug-verbose": ("DebugVerbose", True, True, False),
    "debug-fallback": ("DebugFallback", True, True, True),
    "production": ("Production", False, False, False),
    "production-fallback": ("ProductionFallback", False, False, True),
}


def build(variant, identity="-", version="0.1.0", skip=False, coverage=False):
    configuration, debug, verbose, fallback = VARIANTS[variant]
    if not skip:
        subprocess.run(["xcodebuild", "-project", "MView.xcodeproj", "-scheme", "mview",
                        "-configuration", configuration, "build"], cwd=ROOT, check=True)
    driver = ROOT / "build" / configuration / "mview"
    info = json.loads(subprocess.check_output([str(driver), "build-info"]))
    expected = dict(product="Mview", diagnostics=debug, verbose=verbose, displaylink_fallback=fallback)
    if info != expected:
        raise RuntimeError(f"Driver build policy mismatch: {info} != {expected}")
    # Separate output from the previous developer app. Never replace a running bundle.
    bundle = ROOT / "build/apps" / variant / "Mview.app"
    running = subprocess.check_output(["ps", "-axo", "command"], text=True)
    if str(bundle / "Contents/MacOS/") in running:
        raise RuntimeError("Quit this variant before replacing its app bundle")
    if bundle.exists(): shutil.rmtree(bundle)
    contents = bundle / "Contents"
    binaries = contents / "MacOS"
    binaries.mkdir(parents=True)
    sources = sorted((ROOT / "Sources/MViewApp").glob("*.swift"))
    # Swift top-level statements must be in main.swift when compiling multiple files.
    main = bundle.parent / "main.swift"
    main.write_text((ROOT / "Sources/MViewApp/Main.swift").read_text())
    command = ["xcrun", "swiftc", "-O", "-swift-version", "5", "-target", "arm64-apple-macosx14.0",
               "-module-cache-path", str(ROOT / "build/ModuleCache"),
               "-D", "MVIEW_DIAGNOSTICS" if debug else "MVIEW_PRODUCTION"]
    if coverage: command += ["-profile-generate", "-profile-coverage-mapping"]
    command += [str(main), *[str(p) for p in sources if p.name != "Main.swift"], "-o", str(binaries / "Mview")]
    subprocess.run(command, check=True)
    shutil.copy2(driver, binaries / "MviewDriver")
    if debug:
        subprocess.run(["xcrun", "swiftc", "-O", "-module-cache-path", str(ROOT / "build/ModuleCache"),
                        "-target", "arm64-apple-macosx14.0", str(ROOT / "Tools/MotionBench.swift"),
                        "-o", str(binaries / "MviewMotionBench")], check=True)
    if (binaries / "Mview").samefile(binaries / "MviewDriver"):
        raise RuntimeError("App and driver must have distinct filenames on case-insensitive filesystems")
    plist = {
        "CFBundleIdentifier": "org.mview.Mview." + variant,
        "CFBundleName": "Mview", "CFBundleDisplayName": "Mview",
        "CFBundleExecutable": "Mview", "CFBundlePackageType": "APPL",
        "CFBundleShortVersionString": version, "CFBundleVersion": version,
        "LSMinimumSystemVersion": "14.0", "LSUIElement": True,
        "NSHighResolutionCapable": True,
        "MviewVariant": variant, "MviewFallback": fallback,
    }
    (contents / "Info.plist").write_bytes(plistlib.dumps(plist))
    (contents / "Resources").mkdir()
    (contents / "Resources/build-info.json").write_text(json.dumps(info, indent=2) + "\n")
    signing = ["codesign", "--force", "--sign", identity, "--options", "runtime"]
    if identity != "-": signing += ["--timestamp"]
    for binary in sorted(binaries.iterdir()): subprocess.run([*signing, str(binary)], check=True)
    subprocess.run([*signing, str(bundle)], check=True)
    subprocess.run(["codesign", "--verify", "--deep", "--strict", str(bundle)], check=True)
    print(bundle)
    if identity == "-": print("Local ad-hoc build. Distribution requires Developer ID signing and notarization.")
    return bundle


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--variant", choices=VARIANTS, default="debug-minimal")
    parser.add_argument("--skip-driver-build", action="store_true")
    parser.add_argument("--sign", default="-")
    parser.add_argument("--version", default="0.1.0")
    parser.add_argument("--coverage", action="store_true")
    args = parser.parse_args()
    build(args.variant, args.sign, args.version, args.skip_driver_build, args.coverage)


if __name__ == "__main__": main()
