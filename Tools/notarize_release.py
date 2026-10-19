#!/usr/bin/env python3
"""Submit one release archive to Apple, require acceptance, and staple its ticket."""
import argparse
import json
from pathlib import Path
import subprocess
import sys


def notarize(upload, staple, key, key_id, issuer):
    auth = ["--key", str(key), "--key-id", key_id, "--issuer", issuer]
    result = subprocess.run(["xcrun", "notarytool", "submit", str(upload), *auth,
                             "--wait", "--timeout", "2h", "--output-format", "json"],
                            check=True, capture_output=True, text=True)
    response = json.loads(result.stdout)
    submission = response.get("id", "unknown")
    if response.get("status") != "Accepted":
        if submission != "unknown":
            log = subprocess.run(["xcrun", "notarytool", "log", submission, *auth],
                                 capture_output=True, text=True, check=False)
            print(log.stdout or log.stderr, file=sys.stderr)
        raise RuntimeError(f"Apple did not accept {upload}: {response.get('status')} ({submission})")
    if staple:
        subprocess.run(["xcrun", "stapler", "staple", str(staple)], check=True)
        subprocess.run(["xcrun", "stapler", "validate", str(staple)], check=True)
    print(f"Accepted{' and stapled' if staple else ''}: {staple or upload} ({submission})")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("upload", type=Path, help="ZIP, signed PKG, or DMG sent to Apple")
    parser.add_argument("--staple", type=Path, help="app, PKG, or DMG to staple")
    parser.add_argument("--key", type=Path, required=True, help="App Store Connect team API key file")
    parser.add_argument("--key-id", required=True)
    parser.add_argument("--issuer", required=True)
    args = parser.parse_args()
    if args.upload.suffix not in (".zip", ".pkg", ".dmg"):
        parser.error("upload must be a ZIP, PKG, or DMG")
    if args.staple and args.staple.suffix not in (".app", ".pkg", ".dmg"):
        parser.error("staple target must be an app, PKG, or DMG")
    if not args.upload.is_file() or (args.staple and not args.staple.exists()) or not args.key.is_file():
        parser.error("upload, optional staple target, and API key must exist")
    try:
        notarize(args.upload, args.staple, args.key, args.key_id, args.issuer)
    except (OSError, ValueError, subprocess.SubprocessError, RuntimeError) as error:
        parser.exit(1, f"Notarization failed: {error}\n")


if __name__ == "__main__":
    main()
