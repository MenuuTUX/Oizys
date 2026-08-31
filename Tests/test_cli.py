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
