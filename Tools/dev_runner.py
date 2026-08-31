"""Process supervisor for the developer GUI. Requests arrive on a private stdin pipe."""
import json
import fcntl
import os
from pathlib import Path
import resource
import signal
import subprocess
import sys

sys.dont_write_bytecode = True
import fixture

ROOT = Path(__file__).resolve().parent.parent


def interrupted(*_):
    signal.signal(signal.SIGINT, signal.SIG_IGN)
    signal.signal(signal.SIGTERM, signal.SIG_IGN)
    raise KeyboardInterrupt


def private_request(request):
    # This entry uses a pipe instead of a terminal prompt. It performs the same
    # decryption on every operation; the GUI shortcut itself grants no access.
    action = request["action"]
    if action == "prepare":
        print("Installing the isolated tools. This can take a few minutes.", flush=True)
        result = fixture.run_child([sys.executable, str(ROOT / "Tools/setup_debug.py")],
                                   capture_output=True, timeout=1700, cwd=ROOT)
        if result.returncode:
            raise fixture.FixtureError("Tool setup failed. Check your internet connection and retry Prepare required tools.")
        print("Required tools are ready. Unlock and choose Check sources or Run.", flush=True)
        return 0
    phrase = request.pop("passphrase")
    if not isinstance(phrase, str) or not phrase or len(phrase) > 4096:
        raise fixture.FixtureInputError("Enter your passphrase.")
    binary = fixture.build_player()
    if action == "replace":
        fixture.replace_settings(binary, fixture.SETTINGS, request["source"], phrase)
        print("New settings saved and unlocked. The previous encrypted settings were kept as a private backup.", flush=True)
        return 0
    if action == "init":
        if len(phrase) < 16:
            raise fixture.FixtureInputError("Use a passphrase of at least 16 characters")
        fixture.seal_settings(binary, fixture.SETTINGS, request["source"], phrase)
        print("Local settings initialized.", flush=True)
        return 0
    if not fixture.SETTINGS.exists():
        raise fixture.FixtureError("No local settings found. Close and reopen this window to create them.")
    if action == "unlock":
        fixture.check_crypto(binary)
        print("Local unlock helper checked.", flush=True)
    source = fixture.open_settings(binary, fixture.SETTINGS, phrase)
    if action == "unlock":
        print("Unlocked for this window session.", flush=True)
        return 0
    if action == "source":
        fixture.seal_settings(binary, fixture.SETTINGS, request["source"], phrase, replace=True)
        print("Local settings updated.", flush=True)
        return 0
    if action not in ("run", "check"):
        raise ValueError("Invalid operation")
    del phrase
    seconds, fraction = float(request["seconds"]), float(request["fraction"])
    count, limit, fps = int(request["count"]), int(request["perScreen"]), float(request["minFPS"])
    if not (1 <= seconds <= 3600 and .1 <= fraction <= 1 and 2 <= count <= 96
            and 0 <= limit <= 96 and 0 <= fps <= 240):
        raise ValueError("Invalid workload limits")
    print("Finding publicly accessible clips. Your source stays hidden.", flush=True)
    return fixture.run_fixture(binary, source, count, seconds, request.get("full") is True,
                               fraction, action == "check", limit, fps)


def main():
    if sys.platform != "darwin" or os.environ.get("CONFIGURATION", "").lower().startswith(("production", "release")):
        return 2
    resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
    if os.getpgrp() != os.getpid():
        os.setsid()
    signal.signal(signal.SIGINT, interrupted)
    signal.signal(signal.SIGTERM, interrupted)
    private = False
    try:
        raw = sys.stdin.buffer.read(65537)
        if len(raw) > 65536:
            raise ValueError("Request too large")
        request = json.loads(raw)
        del raw
        private = request.get("tool") == "fixture"
        if private:
            return private_request(request)
        name = request["tool"]
        args = request.get("arguments", [])
        if not isinstance(args, list) or not all(isinstance(a, str) for a in args):
            raise ValueError("Invalid arguments")
        if name not in ("test.py", "profile.py", "measure_processes.py", "report.py", "setup_debug.py"):
            raise ValueError("Unknown tool")
        (ROOT / "build").mkdir(exist_ok=True)
        # run_child owns and cancels the entire compiler/downloader/test tree.
        with (ROOT / "build/dev-tools.lock").open("w") as lock:
            try:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError:
                raise ValueError("Another developer GUI is already running a repository tool")
            return fixture.run_child([sys.executable, "-u", str(ROOT / "Tools" / name), *args],
                                     cwd=ROOT).returncode
    except (KeyboardInterrupt, EOFError):
        return 130
    except Exception as error:
        # Never echo source URLs, signed CDN URLs, passwords, or decrypt requests.
        if private:
            print(str(error) if isinstance(error, fixture.FixtureError) else
                  "Local operation failed. Retry Prepare required tools, then Check sources. No secrets were logged.", file=sys.stderr)
        else:
            print(f"Developer tool failed: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
