#!/usr/bin/env python3
"""Replace installed Oizys copies with one production app, CLI and per-user login service."""
import argparse
import json
import os
from pathlib import Path
import plistlib
import shutil
import signal
import subprocess
import tempfile
import time

LABEL = "org.oizys.Oizys.login"


def app_info(bundle):
    try: return plistlib.loads((bundle / "Contents/Info.plist").read_bytes())
    except (OSError, ValueError): return {}


def owned(bundle):
    return str(app_info(bundle).get("CFBundleIdentifier", "")).startswith("org.oizys.")


def running_apps():
    rows = []
    output = subprocess.check_output(["ps", "-axo", "pid=,ppid=,uid=,comm="], text=True)
    for line in output.splitlines():
        fields = line.split(None, 3)
        if len(fields) != 4 or fields[2] != str(os.getuid()) or ".app/Contents/MacOS/" not in fields[3]: continue
        path = Path(fields[3])
        info = app_info(path.parent.parent.parent)
        if str(info.get("CFBundleIdentifier", "")).startswith("org.oizys."):
            rows.append((int(fields[0]), int(fields[1]), path, info))
    return rows


def stop_apps():
    signaled, killed = set(), set()
    started = time.monotonic()
    # An older app that ignores SIGTERM must not block installing the version that fixes it.
    while time.monotonic() - started < 25:
        rows = running_apps()
        if not rows: return
        pids = {row[0] for row in rows}
        force = time.monotonic() - started > 10
        for pid, parent, _, _ in rows:
            if parent in pids: continue
            if pid not in signaled: number = signal.SIGTERM
            elif force and pid not in killed: number = signal.SIGKILL
            else: continue
            try: os.kill(pid, number)
            except ProcessLookupError: pass
            (killed if number == signal.SIGKILL else signaled).add(pid)
        time.sleep(.2)
    raise RuntimeError("An old Oizys process has not stopped; installation was not replaced")


def launchctl(*arguments, check=False):
    return subprocess.run(["/bin/launchctl", *arguments], check=check,
                          stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def cli_location():
    for directory in (Path("/opt/homebrew/bin"), Path("/usr/local/bin"), Path.home() / ".local/bin"):
        if not directory.exists() and directory == Path.home() / ".local/bin":
            directory.mkdir(parents=True, exist_ok=True)
        if directory.is_dir() and os.access(directory, os.W_OK):
            path = directory / "oizys"
            if path.exists() or path.is_symlink():
                if not path.is_symlink() or not str(path.readlink()).startswith(("/Applications/", str(Path.home() / "Applications"))):
                    raise RuntimeError(f"Refusing to overwrite an unrelated CLI: {path}")
                if path.resolve().name != "OizysDriver":
                    raise RuntimeError(f"Refusing to overwrite an unrelated CLI symlink: {path}")
            return path
    raise RuntimeError("No writable CLI directory")


def install(bundle, applications=Path("/Applications"), login=True):
    if os.getuid() == 0:
        raise RuntimeError("Run as the logged-in user, not sudo: the login service and privacy identity are per-user.")
    info = app_info(bundle)
    variant = info.get("OizysVariant", "")
    if not owned(bundle) or variant not in ("production", "production-fallback"):
        raise ValueError("Only production is installed. Debug builds are portable executables.")
    policy = json.loads((bundle / "Contents/Resources/build-info.json").read_text())
    if policy["diagnostics"] or policy["verbose"] or policy["displaylink_fallback"] != (variant == "production-fallback"):
        raise ValueError("Production build policy mismatch")
    subprocess.run(["codesign", "--verify", "--deep", "--strict", str(bundle)], check=True)
    applications.mkdir(parents=True, exist_ok=True)
    destination = applications / "Oizys.app"
    if destination.exists() and not owned(destination):
        raise ValueError("Refusing to replace an unrelated application")
    installed = set()
    for directory in {applications, Path("/Applications"), Path.home() / "Applications"}:
        if directory.is_dir():
            installed.update(path for path in directory.glob("*.app") if owned(path) and not path.is_symlink())
    agent = Path.home() / "Library/LaunchAgents" / (LABEL + ".plist")
    domain = f"gui/{os.getuid()}"
    loaded = launchctl("print", f"{domain}/{LABEL}").returncode == 0
    old_agent = agent.read_bytes() if agent.exists() else None
    link = cli_location()
    old_link = link.readlink() if link.is_symlink() else None
    obsolete_agents = []
    if agent.parent.exists():
        for candidate in agent.parent.glob("*.plist"):
            if candidate == agent: continue
            try: value = plistlib.loads(candidate.read_bytes())
            except (OSError, ValueError): continue
            label = str(value.get("Label", ""))
            if label.lower().startswith("org.oizys."):
                obsolete_agents.append((candidate, label))
    # Stage and verify every byte before interrupting the current driver.
    with tempfile.TemporaryDirectory(prefix=".oizys-install-", dir=applications) as temporary:
        temporary = Path(temporary)
        staged = temporary / "Oizys.app"
        shutil.copytree(bundle, staged)
        subprocess.run(["codesign", "--verify", "--deep", "--strict", str(staged)], check=True)
        moved = []
        placed = False
        try:
            launchctl("bootout", f"{domain}/{LABEL}")
            for _, label in obsolete_agents: launchctl("bootout", f"{domain}/{label}")
            stop_apps()
            # Older debug apps can restore production as they quit; stop that restored job too.
            launchctl("bootout", f"{domain}/{LABEL}")
            stop_apps()
            # The shared CLI also stops standalone supervised developer drivers.
            subprocess.run([str(staged / "Contents/MacOS/OizysDriver"), "service", "stop"], check=True)
            for index, path in enumerate(sorted(installed)):
                backup = temporary / f"previous-{index}.app"
                path.rename(backup); moved.append((path, backup))
            staged.rename(destination); placed = True
            agent.parent.mkdir(parents=True, exist_ok=True)
            value = {
                "Label": LABEL,
                # LaunchServices preserves TCC identity; -W ties the job to app lifetime.
                # Exec the binary rather than going through `open`. LaunchServices leaves the app
            # without its own TCC identity that way, so the bundle's Screen Recording grant
            # does not apply to it and the supervisor parks on a failed preflight forever,
            # silently, while the CLI reports the permission as granted because that is a
            # different binary. Launched directly the app is its own responsible process.
            "ProgramArguments": [str(destination / "Contents/MacOS/Oizys"), "--background"],
                "RunAtLoad": True, "KeepAlive": True,
                "LimitLoadToSessionType": "Aqua", "ProcessType": "Interactive",
                "ThrottleInterval": 10, "ExitTimeOut": 8,
                "AssociatedBundleIdentifiers": [info["CFBundleIdentifier"]],
                "StandardOutPath": "/dev/null", "StandardErrorPath": "/dev/null",
            }
            staging_agent = agent.with_suffix(".plist.tmp")
            staging_agent.write_bytes(plistlib.dumps(value)); staging_agent.chmod(0o644); staging_agent.replace(agent)
            if login:
                launchctl("enable", f"{domain}/{LABEL}", check=True)
                launchctl("bootstrap", domain, str(agent), check=True)
            else:
                launchctl("disable", f"{domain}/{LABEL}", check=True)
            temporary_link = link.with_name(".oizys-link-" + str(os.getpid()))
            try:
                temporary_link.symlink_to(destination / "Contents/MacOS/OizysDriver")
                temporary_link.replace(link)
            finally: temporary_link.unlink(missing_ok=True)
        except Exception:
            launchctl("bootout", f"{domain}/{LABEL}")
            if placed:
                stop_apps(); shutil.rmtree(destination)
            for path, backup in reversed(moved): backup.rename(path)
            if old_agent: agent.write_bytes(old_agent)
            else: agent.unlink(missing_ok=True)
            if old_link:
                link.unlink(missing_ok=True); link.symlink_to(old_link)
            elif link.is_symlink(): link.unlink()
            if loaded and old_agent: launchctl("bootstrap", domain, str(agent))
            raise
        for candidate, _ in obsolete_agents: candidate.unlink(missing_ok=True)
        # Successful installation removes all superseded app bundles, including debug.
    print(f"Installed: {destination} ({info['CFBundleShortVersionString']}, {variant})")
    print(f"CLI: {link}")
    if str(link.parent) not in os.environ.get("PATH", "").split(os.pathsep):
        print(f"Add {link.parent} to PATH, or invoke the CLI by its full path.")
    print(f"Login startup: {'enabled' if login else 'disabled'}; {agent}")
    print(f"Removed {len(installed)} previous installation(s). Private settings and permissions were preserved.")
    return destination


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("bundle", type=Path)
    parser.add_argument("--applications", type=Path, default=Path("/Applications"))
    parser.add_argument("--no-login", action="store_true")
    args = parser.parse_args()
    install(args.bundle.resolve(), args.applications.resolve(), not args.no_login)
