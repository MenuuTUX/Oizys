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
import sys
import tempfile
import time

LABEL = "org.oizys.Oizys.login"
# The one privacy permission Oizys asks for. Nothing else here touches TCC.
TCC_SERVICE = "ScreenCapture"


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


def oizys_identifiers(bundles):
    """Every org.oizys.* bundle identifier among these bundles, and nothing else."""
    found = set()
    for path in bundles:
        identifier = str(app_info(path).get("CFBundleIdentifier", ""))
        if identifier.startswith("org.oizys."):
            found.add(identifier)
    return sorted(found)


def reset_permissions(identifiers):
    """
    Drop Oizys's own Screen Recording approval so the build being installed asks for its own.

    macOS keys this permission to a code-signing identity, and an ad-hoc signed build gets a
    fresh one every time it is rebuilt. The old approval outlives the bundle it was granted
    to, which produces the worst of both states: System Settings shows Oizys ticked, every
    preflight fails, and the login agent exits, is respawned ten seconds later, and repeats
    that forever without a prompt or a line of output. Clearing the entry costs one question
    the user can actually answer.

    The running service still never goes near TCC -- see OizysLifecycle.command. This is an
    installer, acting on identifiers it owns, during an install somebody asked for, and it
    says on stdout what it cleared.
    """
    cleared = []
    for identifier in identifiers:
        if not identifier.startswith("org.oizys."):
            continue
        result = subprocess.run(["/usr/bin/tccutil", "reset", TCC_SERVICE, identifier],
                                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        if result.returncode == 0:
            cleared.append(identifier)
    return cleared


def screen_recording_granted(destination):
    """What the driver's own preflight says. The agent runs the driver, not the app wrapper,
    and on an ad-hoc bundle the two do not necessarily share an identity."""
    driver = destination / "Contents/MacOS/OizysDriver"
    try:
        result = subprocess.run([str(driver), "service", "status"], text=True,
                                capture_output=True, check=False, timeout=20)
    except (OSError, subprocess.SubprocessError):
        return False
    return "access for this executable: granted" in (result.stdout or "")


SCREEN_RECORDING_PANE = ("x-apple.systempreferences:"
                         "com.apple.preference.security?Privacy_ScreenCapture")


def request_permission(destination, timeout=300, settle=90):
    """Ask while somebody is still at the keyboard.

    The alternative is an install that reports success and leaves a dark desk, because the
    only thing between the two is a checkbox nothing has prompted for yet.

    Two attempts, because the first one is not dependable. The app's own dialog is the nicer
    of the two, but an installer run from a shell does not always hold a window server session
    to put a modal on, and when it does not the dialog never appears and nothing says so. The
    settings pane always opens, so that is the fallback, and then this waits: an install that
    ends the moment it opens a pane has handed the problem back rather than finished it.
    """
    app = destination / "Contents/MacOS/Oizys"
    if app.exists():
        try:
            subprocess.run([str(app), "--permissions-only"], check=False, timeout=timeout)
        except (OSError, subprocess.SubprocessError):
            pass
    if screen_recording_granted(destination):
        return True
    # Only wait when a person is watching. Under CI or a pipe there is nobody to tick it, and
    # a scripted install must not sit here for a minute and a half to find that out.
    if not (settle and sys.stdout.isatty()):
        return False
    subprocess.run(["/usr/bin/open", SCREEN_RECORDING_PANE], check=False)
    print("Waiting for Screen Recording: tick Oizys in the window that just opened…",
          flush=True)
    deadline = time.monotonic() + settle
    while time.monotonic() < deadline:
        if screen_recording_granted(destination):
            return True
        time.sleep(2)
    return False


def install(bundle, applications=Path("/Applications"), login=True,
            keep_permissions=False, prompt=True):
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
    # Read the identifiers now: the bundles carrying them are about to be removed, and a
    # superseded variant's stale approval is exactly the one worth clearing.
    identifiers = oizys_identifiers({*installed, bundle})
    agent = Path.home() / "Library/LaunchAgents" / (LABEL + ".plist")
    domain = f"gui/{os.getuid()}"
    loaded = launchctl("print", f"{domain}/{LABEL}").returncode == 0
    old_agent = agent.read_bytes() if agent.exists() else None
    link = cli_location()
    old_link = link.readlink() if link.is_symlink() else None
    workspace = Path.home() / "Library/Application Support/Oizys"
    service_log = workspace / "logs/service.log"
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
            service_log.parent.mkdir(parents=True, exist_ok=True)
            service_log.write_text("")
            value = {
                "Label": LABEL,
                # Run the app, which spawns the driver as its child.
                #
                # This ran the driver directly for a while, to dodge the app's Screen Recording
                # preflight. That trade was worse than the problem: Screen Recording is granted
                # to a code signature, the driver is a separate executable with a separate one,
                # and nothing the user can click grants the driver -- so the agent started,
                # refused, exited, and was respawned every ten seconds for ever. A child process
                # inherits the responsible process's access, so with the app in front there is
                # one thing to grant and one place to grant it (About > Grant). It also means
                # the menu-bar item is always up, instead of depending on somebody launching
                # the app by hand after every install.
                "ProgramArguments": [str(destination / "Contents/MacOS/Oizys"), "--background"],
                "WorkingDirectory": str(Path.home() / "Library/Application Support/Oizys"),
                "RunAtLoad": True, "KeepAlive": True,
                "LimitLoadToSessionType": "Aqua", "ProcessType": "Interactive",
                "ThrottleInterval": 10, "ExitTimeOut": 8,
                "AssociatedBundleIdentifiers": [info["CFBundleIdentifier"]],
                # stdout is chatty and says nothing useful once running; stderr is where a
                # refusal to start goes. Throwing it away is what turned a missing permission
                # into a job that respawns every ten seconds and never explains itself.
                # ponytail: no rotation. The file only grows while the driver is failing to
                # start, and each install truncates it; add rotation if that stops being true.
                "StandardOutPath": "/dev/null",
                "StandardErrorPath": str(service_log),
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
    print(f"Service log: {service_log}")
    # The agent brings the app up, and with it the menu-bar item; bootstrap has already run by
    # the time this prints. Nothing to launch by hand.
    print(f"Removed {len(installed)} previous installation(s). Your settings were kept.")

    # Only once the new bundle is in place and the old ones are gone: a rollback restores an
    # app whose approval should still be its own.
    if keep_permissions:
        granted = screen_recording_granted(destination)
        print("Screen Recording: left as it was "
              f"({'granted' if granted else 'NOT granted'} for this build).")
    else:
        cleared = reset_permissions(identifiers)
        print("Screen Recording: cleared for " + (", ".join(cleared) if cleared else "nothing")
              + " so this build asks for its own.")
        granted = request_permission(destination) if prompt else False
        if granted:
            print("Screen Recording: granted. The driver starts on its own.")
        else:
            print("Screen Recording: still needed. Enable Oizys under System Settings > Privacy "
                  "& Security > Screen & System Audio Recording; the login agent picks it up "
                  "within a few seconds. Until then it retries quietly and logs to the file above.")
    return destination


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("bundle", type=Path)
    parser.add_argument("--applications", type=Path, default=Path("/Applications"))
    parser.add_argument("--no-login", action="store_true")
    parser.add_argument("--keep-permissions", action="store_true",
                        help="do not clear Oizys's own Screen Recording approval")
    parser.add_argument("--no-prompt", action="store_true",
                        help="never open the permission dialog; report what is missing instead")
    args = parser.parse_args()
    install(args.bundle.resolve(), args.applications.resolve(), not args.no_login,
            keep_permissions=args.keep_permissions, prompt=not args.no_prompt)
