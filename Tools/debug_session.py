"""Stop the selected local debug app before rebuilding it. Never stop production."""
import os
import json
from pathlib import Path
import plistlib
import signal
import subprocess
import time


def processes():
    output = subprocess.check_output(
        ["ps", "-U", str(os.getuid()), "-o", "pid=,ppid=,comm="], text=True)
    result = {}
    for line in output.splitlines():
        fields = line.strip().split(None, 2)
        if len(fields) == 3:
            result[int(fields[0])] = (int(fields[1]), fields[2])
    return result


def selected_app(executable, root, variant, cache):
    path = Path(executable)
    if path.name != "Oizys-debug" or path.parent.name != "MacOS":
        return False
    bundle = path.parent.parent.parent
    if bundle.name != "Oizys-debug.app" or path.parent.parent.name != "Contents":
        return False
    if not (bundle.is_relative_to(root / "build") or bundle.is_relative_to(cache)):
        return False
    try:
        info = plistlib.loads((bundle / "Contents/Info.plist").read_bytes())
        return (info.get("CFBundleIdentifier") == "org.oizys.Oizys." + variant
                and info.get("OizysVariant") == variant)
    except (OSError, ValueError):
        return False


def signal_matching(targets, number):
    current = processes()
    for pid, executable in targets.items():
        if current.get(pid, (None, None))[1] == executable:
            try:
                os.kill(pid, number)
            except ProcessLookupError:
                pass


def wait_for_exit(targets, seconds):
    deadline = time.monotonic() + seconds
    while True:
        current = processes()
        remaining = {pid: path for pid, path in targets.items()
                     if current.get(pid, (None, None))[1] == path}
        if not remaining or time.monotonic() >= deadline:
            return remaining
        time.sleep(0.2)


def stop_debug(root, variant):
    if variant not in ("debug-minimal", "debug-verbose", "debug-fallback"):
        raise ValueError("Automatic replacement is only available for debug variants")
    cache = Path.home() / "Library/Caches/Oizys/Portable"
    snapshot = processes()
    apps = {pid: path for pid, (_, path) in snapshot.items()
            if selected_app(path, root, variant, cache)}
    if not apps:
        return
    # Remember owned helpers before the app exits and their parent PIDs change.
    owned = dict(apps)
    while True:
        children = {pid: path for pid, (parent, path) in snapshot.items()
                    if parent in owned and pid not in owned
                    and "/Oizys.app/Contents/" not in path}
        if not children:
            break
        owned.update(children)
    print(f"Closing the previous {variant} session before rebuilding…", flush=True)
    signal_matching(apps, signal.SIGTERM)
    # The app allows up to 20 seconds to finish its driver and tool cleanup.
    wait_for_exit(apps, 25)
    remaining = wait_for_exit(owned, 0)
    if remaining:
        print("Stopping leftover debug processes…", flush=True)
        signal_matching(remaining, signal.SIGTERM)
        remaining = wait_for_exit(remaining, 3)
        signal_matching(remaining, signal.SIGKILL)
        if wait_for_exit(remaining, 3):
            raise RuntimeError("The previous debug session could not stop; its build was left unchanged")
    # Recover only a lease owned by an app we stopped, never an unrelated session.
    lease = Path.home() / "Library/Application Support/Oizys/development-session.json"
    try:
        owner = json.loads(lease.read_text()).get("pid")
    except (OSError, ValueError):
        owner = None
    if owner not in apps:
        return
    driver = Path("/Applications/Oizys.app/Contents/MacOS/OizysDriver")
    if not driver.is_file():
        driver = Path(next(iter(apps.values()))).with_name("OizysDriver")
    subprocess.run([str(driver), "service", "recover-debug"], check=True, timeout=30)
