"""Release packaging gates, with Apple commands replaced by deterministic results."""
import json
from pathlib import Path
import subprocess
import sys

import pytest

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "Tools"))
import build_app
import make_dmg
import notarize_release
import package_resources


def test_signed_pkg_uses_installer_identity(tmp_path, monkeypatch):
    monkeypatch.setattr(build_app, "ROOT", tmp_path)
    bundle = tmp_path / "build/apps/production/1.2.3/Oizys.app"
    bundle.mkdir(parents=True)
    calls = []
    monkeypatch.setattr(build_app.subprocess, "run", lambda command, **kwargs: calls.append(command))
    build_app.package_staged("production", "Developer ID Application: Example", "1.2.3",
                             "installer", "Developer ID Installer: Example", "/tmp/keys.keychain-db")
    pkgbuild = next(command for command in calls if command[0] == "pkgbuild")
    assert pkgbuild[pkgbuild.index("--sign") + 1] == "Developer ID Installer: Example"
    assert pkgbuild[pkgbuild.index("--keychain") + 1] == "/tmp/keys.keychain-db"


def test_distribution_debug_omits_debugger_entitlement(tmp_path, monkeypatch):
    monkeypatch.setattr(package_resources, "ROOT", tmp_path)
    assets = tmp_path / "Assets"
    assets.mkdir()
    for name in ("Logo.png", "tiny_Logo.png"):
        (assets / name).write_bytes(b"image")
    driver = tmp_path / "oizys"
    driver.write_bytes(b"driver")
    monkeypatch.setattr(package_resources, "app_icon", lambda path: path.write_bytes(b"icon"))
    monkeypatch.setattr(package_resources.subprocess, "check_output", lambda *args, **kwargs:
                        b'{"diagnostics": true}')
    commands = []
    monkeypatch.setattr(package_resources.subprocess, "run", lambda command, **kwargs:
                        commands.append(command))
    monkeypatch.setenv("OIZYS_DISTRIBUTION", "YES")
    package_resources.package(tmp_path / "Oizys-debug.app", driver, True,
                              "Developer ID Application: Example")
    signs = [command for command in commands if command[0] == "codesign"]
    assert len(signs) == 2
    assert all("--timestamp" in command and "--entitlements" not in command for command in signs)
    commands.clear()
    monkeypatch.delenv("OIZYS_DISTRIBUTION")
    package_resources.package(tmp_path / "Oizys-debug.app", driver, True, "-")
    signs = [command for command in commands if command[0] == "codesign"]
    assert all("--entitlements" in command for command in signs)


def test_notary_rejection_never_staples(tmp_path, monkeypatch):
    calls = []
    def run(command, **kwargs):
        calls.append(command)
        if command[1:3] == ["notarytool", "submit"]:
            return subprocess.CompletedProcess(command, 0, json.dumps({"status": "Invalid", "id": "example"}))
        return subprocess.CompletedProcess(command, 0, "details")
    monkeypatch.setattr(notarize_release.subprocess, "run", run)
    with pytest.raises(RuntimeError, match="did not accept"):
        notarize_release.notarize(tmp_path / "app.zip", tmp_path / "Oizys.app",
                                  tmp_path / "key.p8", "KEY", "ISSUER")
    assert not any(command[1] == "stapler" for command in calls)


def test_notary_acceptance_staples_and_validates(tmp_path, monkeypatch):
    calls = []
    def run(command, **kwargs):
        calls.append(command)
        return subprocess.CompletedProcess(command, 0, json.dumps({"status": "Accepted", "id": "example"}))
    monkeypatch.setattr(notarize_release.subprocess, "run", run)
    notarize_release.notarize(tmp_path / "app.zip", tmp_path / "Oizys.app",
                              tmp_path / "key.p8", "KEY", "ISSUER")
    assert [command[1:3] for command in calls] == [["notarytool", "submit"],
                                                      ["stapler", "staple"], ["stapler", "validate"]]


def test_all_release_dmg_names_are_unique(tmp_path, monkeypatch):
    monkeypatch.setattr(make_dmg, "ROOT", tmp_path)
    calls = []
    monkeypatch.setattr(make_dmg, "variant_payload", lambda variant, staging, version, distribution: variant)
    monkeypatch.setattr(make_dmg.subprocess, "run", lambda command, **kwargs: calls.append(command))
    names = {make_dmg.build(variant, tmp_path, "1.2.3", True).name
             for variant in build_app.VARIANTS}
    assert len(names) == 5
