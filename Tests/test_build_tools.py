"""Packaging and installation use real temporary files; OS mutations are intercepted."""
import importlib.util
import json
from pathlib import Path
import plistlib
import subprocess
import sys

import pytest

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "Tools"))
import build_app
import install_app
import package_resources


def bundle(path, variant="production", identifier="org.oizys.Oizys.production"):
    (path / "Contents/Resources").mkdir(parents=True)
    (path / "Contents/MacOS").mkdir()
    (path / "Contents/Info.plist").write_bytes(plistlib.dumps({
        "CFBundleIdentifier": identifier, "OizysVariant": variant,
        "CFBundleShortVersionString": "0.3.0",
    }))
    (path / "Contents/Resources/build-info.json").write_text(json.dumps({
        "diagnostics": False, "verbose": False, "displaylink_fallback": variant == "production-fallback",
    }))
    (path / "Contents/MacOS/OizysDriver").write_bytes(b"new driver")
    return path


@pytest.fixture
def installation(tmp_path, monkeypatch):
    home = tmp_path / "home"
    home.mkdir()
    monkeypatch.setattr(Path, "home", classmethod(lambda cls: home))
    link = home / "oizys"
    monkeypatch.setattr(install_app, "cli_location", lambda: link)
    monkeypatch.setattr(install_app, "stop_apps", lambda: None)
    calls = []
    def run(command, **kwargs):
        calls.append(command)
        return subprocess.CompletedProcess(command, 0)
    monkeypatch.setattr(install_app.subprocess, "run", run)
    original_owned = install_app.owned
    monkeypatch.setattr(install_app, "owned", lambda path: path.is_relative_to(tmp_path) and original_owned(path))
    return home, link, calls


@pytest.mark.parametrize("login", [True, False])
def test_install_replaces_only_owned_apps_and_registers_cli(tmp_path, installation, login):
    home, link, calls = installation
    applications = tmp_path / "Applications"
    old = bundle(applications / "Old.app")
    other = bundle(applications / "Other.app", identifier="com.example.other")
    source = bundle(tmp_path / "source.app")
    destination = install_app.install(source, applications, login=login)
    assert destination == applications / "Oizys.app"
    assert not old.exists() and other.exists() and source.exists()
    assert link.resolve() == destination / "Contents/MacOS/OizysDriver"
    agent = home / "Library/LaunchAgents" / (install_app.LABEL + ".plist")
    value = plistlib.loads(agent.read_bytes())
    assert value["AssociatedBundleIdentifiers"] == ["org.oizys.Oizys.production"]
    arguments = value["ProgramArguments"]
    # The agent runs the app, which spawns the driver as a child. Screen Recording is granted
    # to a signature, so running the driver directly needs a grant nothing can offer the user:
    # a child inherits the app's access, leaving one thing to grant and one button to grant it.
    assert arguments[0] == str(destination / "Contents/MacOS/Oizys")
    assert arguments[1:] == ["--background"]
    action = "bootstrap" if login else "disable"
    assert any(command[:2] == ["/bin/launchctl", action] for command in calls)
    assert not list(applications.glob(".oizys-install-*"))


def test_install_clears_only_oizys_screen_recording_approvals(tmp_path, installation):
    # An ad-hoc rebuild keeps the old approval, which then shows as ticked and fails every
    # preflight. Clearing it is the difference between one prompt and a login agent that
    # respawns for ever. It must never reach an identifier Oizys does not own.
    home, _, calls = installation
    applications = tmp_path / "Applications"
    bundle(applications / "Old.app", identifier="org.oizys.Oizys.production-fallback")
    bundle(applications / "Other.app", identifier="com.example.other")
    install_app.install(bundle(tmp_path / "source.app"), applications)
    resets = [command for command in calls if command[:1] == ["/usr/bin/tccutil"]]
    assert [command[3] for command in resets] == ["org.oizys.Oizys.production",
                                                  "org.oizys.Oizys.production-fallback"]
    assert all(command[2] == "ScreenCapture" for command in resets)
    assert not any("com.example.other" in command for command in resets)


def test_install_can_keep_permissions_and_then_never_calls_tccutil(tmp_path, installation):
    home, _, calls = installation
    applications = tmp_path / "Applications"
    install_app.install(bundle(tmp_path / "source.app"), applications, keep_permissions=True)
    assert not any(command[:1] == ["/usr/bin/tccutil"] for command in calls)


def test_install_gives_the_login_agent_somewhere_to_report_a_refusal(tmp_path, installation):
    # stderr going to /dev/null is what hid a missing permission behind a silent respawn.
    home, _, _ = installation
    applications = tmp_path / "Applications"
    install_app.install(bundle(tmp_path / "source.app"), applications)
    agent = home / "Library/LaunchAgents" / (install_app.LABEL + ".plist")
    value = plistlib.loads(agent.read_bytes())
    log = Path(value["StandardErrorPath"])
    assert log != Path("/dev/null") and log.exists()
    assert log.is_relative_to(home / "Library/Application Support/Oizys")


def test_install_rolls_back_app_agent_and_cli_on_startup_failure(tmp_path, installation, monkeypatch):
    home, link, calls = installation
    applications = tmp_path / "Applications"
    old = bundle(applications / "Oizys.app")
    driver = old / "Contents/MacOS/OizysDriver"
    driver.write_bytes(b"previous driver")
    link.symlink_to(driver)
    agent = home / "Library/LaunchAgents" / (install_app.LABEL + ".plist")
    agent.parent.mkdir(parents=True)
    agent.write_bytes(b"previous login job")
    original = install_app.launchctl
    def launch(*args, **kwargs):
        if args[0] == "bootstrap" and kwargs.get("check"):
            raise subprocess.CalledProcessError(5, args)
        return original(*args, **kwargs)
    monkeypatch.setattr(install_app, "launchctl", launch)
    with pytest.raises(subprocess.CalledProcessError):
        install_app.install(bundle(tmp_path / "source.app"), applications)
    assert driver.read_bytes() == b"previous driver"
    assert agent.read_bytes() == b"previous login job"
    assert link.resolve() == driver
    assert not list(applications.glob(".oizys-install-*"))


@pytest.mark.parametrize("variant", ["debug-minimal", "debug-fallback", "unknown"])
def test_install_rejects_nonproduction_before_system_changes(tmp_path, installation, variant):
    _, _, calls = installation
    with pytest.raises(ValueError, match="Only production"):
        install_app.install(bundle(tmp_path / "source.app", variant), tmp_path / "Applications")
    assert calls == []


def test_install_rejects_policy_mismatch(tmp_path, installation):
    source = bundle(tmp_path / "source.app")
    (source / "Contents/Resources/build-info.json").write_text(json.dumps({
        "diagnostics": True, "verbose": False, "displaylink_fallback": False,
    }))
    with pytest.raises(ValueError, match="policy mismatch"):
        install_app.install(source, tmp_path / "Applications")
    assert installation[2] == []


def test_build_validates_version_and_debug_format_before_work(monkeypatch):
    def unexpected(*args, **kwargs):
        pytest.fail("validation must precede subprocesses")
    monkeypatch.setattr(build_app.subprocess, "run", unexpected)
    for value in ("../1", "1.2.3.4", "v1.2", "1; touch x"):
        with pytest.raises(ValueError, match="Version"):
            build_app.build("production", version=value)
    with pytest.raises(ValueError, match="portable"):
        build_app.build("debug-minimal", output_format="installer")


def test_icon_builds_standard_macos_representations(tmp_path):
    output = tmp_path / "Oizys.icns"
    package_resources.app_icon(output)
    data = output.read_bytes()
    assert data[:4] == b"icns" and int.from_bytes(data[4:8], "big") == len(data)
    subprocess.run(["iconutil", "-c", "iconset", str(output)], check=True)
    icons = list((tmp_path / "Oizys.iconset").glob("*.png"))
    assert len(icons) == 10
    assert (tmp_path / "Oizys.iconset/icon_512x512@2x.png").is_file()
    info = plistlib.loads((ROOT / "Sources/OizysApp/Info.plist").read_bytes())
    assert info["CFBundleIconFile"] == output.stem


def test_test_builder_trusts_exit_status_not_success_text(monkeypatch):
    spec = importlib.util.spec_from_file_location("oizys_test_runner", ROOT / "Tools/test.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    monkeypatch.setattr(module.subprocess, "run", lambda *a, **k:
                        subprocess.CompletedProcess(a, 1, "BUILD SUCCEEDED", "failed"))
    with pytest.raises(SystemExit, match="library build failed"):
        module.build()


@pytest.mark.parametrize("value", ["-1", "101", "nan", "inf"])
def test_invalid_coverage_floors_fail_before_building(value):
    result = subprocess.run([sys.executable, str(ROOT / "Tools/test.py"),
                             "--coverage-floor", value], capture_output=True, text=True)
    assert result.returncode == 2 and "between 0 and 100" in result.stderr


def test_production_logging_never_evaluates_arguments_or_needs_a_logger(tmp_path):
    source = tmp_path / "logging.c"
    source.write_text('''#define OIZYS_DIAGNOSTICS 0
#include "oizys_usb.h"
int main(void) {
    int counter = 0;
    int diagnostic_only = 42;
    oizys_log("%d %d", diagnostic_only, ++counter);
    oizys_log_open((++counter, "/must-not-be-opened"));
    return counter;
}
''')
    binary = tmp_path / "logging"
    subprocess.run(["xcrun", "clang", "-Wall", "-Wextra", "-Werror", "-O0",
                    "-I", str(ROOT / "Sources/OizysCore/include"), str(source),
                    "-o", str(binary)], check=True)
    assert subprocess.run([str(binary)]).returncode == 0
