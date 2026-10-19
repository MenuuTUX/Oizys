"""Exercise the shipping CLI without changing displays, services, or user settings."""
import json
import os
from pathlib import Path
import subprocess

import pytest

ROOT = Path(__file__).resolve().parent.parent


@pytest.fixture(scope="module")
def cli():
    coverage = os.environ.get("OIZYS_COVERAGE_DIR")
    if coverage:
        return Path(coverage) / "products/DebugVerbose/oizys"
    result = subprocess.run(["xcodebuild", "-project", str(ROOT / "Oizys.xcodeproj"),
                             "-target", "oizys", "-configuration", "Debug", "build"],
                            capture_output=True, text=True, cwd=ROOT)
    assert result.returncode == 0, result.stdout[-3000:] + result.stderr[-1000:]
    return ROOT / "build/Debug/oizys"


def run(cli, tmp_path, *arguments):
    return subprocess.run([str(cli), *arguments], capture_output=True, text=True, timeout=10,
                          cwd=tmp_path, env=dict(os.environ, OIZYS_CONFIG_PATH=str(tmp_path / "config.json")))


def test_build_policy_and_help(cli, tmp_path):
    result = run(cli, tmp_path, "build-info")
    assert result.returncode == 0
    assert json.loads(result.stdout) == {"product": "Oizys", "diagnostics": True,
                                       "verbose": False if cli.parent.name == "Debug" else True,
                                       "displaylink_fallback": True if cli.parent.name == "Debug" else False}
    result = run(cli, tmp_path, "help")
    assert result.returncode == 0 and "Oizys" in result.stdout


def test_cli_configuration_round_trip(cli, tmp_path):
    assert run(cli, tmp_path, "config", "set", "capture.fps", "30").returncode == 0
    result = run(cli, tmp_path, "config", "get", "capture.fps")
    assert result.returncode == 0 and "30" in result.stdout
    assert run(cli, tmp_path, "config", "reset").returncode == 0
    assert "60" in run(cli, tmp_path, "config", "get", "capture.fps").stdout


def test_config_list_json_keeps_canonical_values_and_defaults(cli, tmp_path):
    device = 'Desk "iPad"\\ Pro'
    assert run(cli, tmp_path, "config", "set", "sidecar.device", device).returncode == 0
    assert run(cli, tmp_path, "config", "set", "capture.fps", "30").returncode == 0
    result = run(cli, tmp_path, "config", "list", "--json")
    assert result.returncode == 0
    listing = json.loads(result.stdout)
    assert listing["version"] == 1
    assert listing["path"] == str(tmp_path / "config.json")
    settings = {row["key"]: row for row in listing["settings"]}
    assert len(settings) == len(listing["settings"])
    assert settings["capture.fps"] == {"key": "capture.fps", "value": "30", "default": "60"}
    assert settings["sidecar.device"] == {"key": "sidecar.device", "value": device, "default": ""}
    human = run(cli, tmp_path, "config", "list")
    assert human.returncode == 0 and human.stdout.startswith(str(tmp_path / "config.json") + "\n")


def test_calibration_clear_removes_both_corrections_together(cli, tmp_path):
    correction = tmp_path / "calibration.json"
    correction.write_text(json.dumps({
        "head.0.r.gain": 0.7, "head.1.r.gain": 0.8,
    }))
    result = run(cli, tmp_path, "calibrate", "clear")
    assert result.returncode == 0, result.stderr
    assert not correction.exists()
    assert run(cli, tmp_path, "calibrate", "clear").returncode == 0


def test_ports_json_is_versioned_and_structured(cli, tmp_path):
    result = run(cli, tmp_path, "ports", "--json")
    assert result.returncode == 0
    listing = json.loads(result.stdout)
    assert listing["version"] == 1
    assert isinstance(listing["ports"], list)
    for port in listing["ports"]:
        assert set(port) == {"depth", "name", "vendor", "vid", "pid", "location_id",
                             "usb_version_bcd", "speed_code", "link_bps", "capable_bps",
                             "sink_ma", "port_limit_ma", "verdict"}
        assert isinstance(port["name"], str) and isinstance(port["vendor"], str)
        assert all(isinstance(port[key], int) for key in ("depth", "vid", "pid", "location_id",
                   "usb_version_bcd", "speed_code", "link_bps", "capable_bps", "sink_ma",
                   "port_limit_ma"))
        assert port["verdict"] is None or isinstance(port["verdict"], str)
    human = run(cli, tmp_path, "ports")
    assert human.returncode == 0 and human.stdout.startswith("Device ")


@pytest.mark.parametrize("value", ["nan", "inf", "-inf", "", "3oops"])
def test_cli_rejects_nonfinite_and_malformed_settings(cli, tmp_path, value):
    result = run(cli, tmp_path, "config", "set", "capture.fps", value)
    assert result.returncode != 0
    assert not (tmp_path / "config.json").exists()


@pytest.mark.parametrize("arguments", [("monitor",), ("monitor", "0", "mode", "1"),
                                        ("monitor", "nan", "position", "0", "0"),
                                        ("service", "unknown-action"), ("tui",)])
def test_cli_rejects_invalid_controls_without_mutations(cli, tmp_path, arguments):
    assert run(cli, tmp_path, *arguments).returncode != 0


@pytest.mark.parametrize("machine_pass", [False, True])
def test_confirmation_records_physical_observation_only_after_machine_pass(cli, tmp_path, machine_pass):
    report = {"machine_pass": machine_pass, "overall_pass": False,
              "overall_note": "overall_pass remains false until a human confirms both physical Dells",
              "physical_output": {"physical_confirmed": False, "transport_pass": machine_pass}}
    path = tmp_path / "logs/verify.json"
    path.parent.mkdir()
    original = json.dumps(report, indent=2) + "\n"
    path.write_text(original)
    result = run(cli, tmp_path, "confirm")
    assert (result.returncode == 0) == machine_pass
    if not machine_pass:
        assert path.read_text() == original
        return
    confirmed = json.loads(path.read_text())
    assert confirmed["overall_pass"] is True
    assert confirmed["physical_output"]["physical_confirmed"] is True
    assert "a human confirmed" in confirmed["overall_note"]
    once = path.read_text()
    assert run(cli, tmp_path, "confirm").returncode == 0
    assert path.read_text() == once
