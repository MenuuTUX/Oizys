"""Exercise app settings through actual subprocesses without touching the dock or user config."""
import json
from pathlib import Path
import subprocess
import sys

import pytest
from Support.native_coverage import flags

ROOT = Path(__file__).resolve().parent.parent


@pytest.fixture(scope="module")
def app_model_test(tmp_path_factory):
    directory = tmp_path_factory.mktemp("app-model")
    binary = directory / "test"
    subprocess.run(["xcrun", "swiftc", "-parse-as-library", "-module-cache-path",
                    str(directory / "modules"), str(ROOT / "Sources/OizysApp/OizysModel.swift"),
                    str(ROOT / "Tests/Support/app_model_test.swift"),
                    *flags(binary, swift=True), "-o", str(binary)], check=True, timeout=120)
    return binary


@pytest.mark.parametrize("mode", ["failed-write", "drag", "read-failure", "states", "refresh-during-drag",
                                  "sidecar-save", "reset-draft", "reset-key", "timeline-report", "timeout"])
def test_app_settings(app_model_test, mode, tmp_path):
    driver = tmp_path / "driver"
    driver.write_text("#!" + sys.executable + "\n" + '''
import json
from pathlib import Path
import sys
folder = Path(__file__).parent
args = sys.argv[1:]
with (folder / "commands.jsonl").open("a") as log:
    log.write(json.dumps(args) + "\\n")
state = folder / "values.json"
values = json.loads(state.read_text()) if state.exists() else {
    "head.left.brightness": "72", "sidecar.auto_connect": "false"}
if args == ["config", "list", "--json"]:
    if (folder / "fail-read").exists():
        print("settings unavailable", file=sys.stderr)
        sys.exit(1)
    print(json.dumps({"version": 1, "path": "/test/oizys.conf", "settings": [
        {"key": key, "value": value, "default": "100" if "brightness" in key else "false"}
        for key, value in values.items()]}))
elif args == ["ports", "--json"]:
    if (folder / "fail-read").exists():
        sys.exit(1)
    print(json.dumps({"version": 1, "ports": []}))
elif args[:2] == ["config", "set"]:
    if (folder / "timeout").exists():
        import signal, time
        signal.signal(signal.SIGTERM, signal.SIG_IGN)
        time.sleep(30)
    if (folder / "fail-write").exists():
        (folder / "fail-read").touch()
        print("write rejected", file=sys.stderr)
        sys.exit(1)
    values[args[2]] = args[3]
    state.write_text(json.dumps(values))
    print("saved")
elif args == ["config", "reset"]:
    state.write_text(json.dumps({"head.left.brightness": "100", "sidecar.auto_connect": "false"}))
    print("reset")
else:
    sys.exit(2)
''')
    driver.chmod(0o700)
    if mode == "failed-write":
        (tmp_path / "fail-write").touch()
    elif mode == "timeout":
        (tmp_path / "timeout").touch()
    result = subprocess.run([str(app_model_test), mode, str(driver)],
                            capture_output=True, text=True, timeout=15)
    assert result.returncode == 0, result.stderr + result.stdout
    assert result.stdout.strip() == "PASS " + mode
    commands = [json.loads(line) for line in (tmp_path / "commands.jsonl").read_text().splitlines()]
    writes = [command for command in commands if command[:2] == ["config", "set"]]
    if mode == "drag":
        assert writes == [["config", "set", "head.left.brightness", "90"]]
        assert commands.count(["ports", "--json"]) == 1, "A setting change needlessly rescanned USB"
    elif mode == "refresh-during-drag":
        assert writes == [["config", "set", "head.left.brightness", "86"]]
    elif mode == "reset-key":
        assert writes == [["config", "set", "head.left.brightness", "100"]]
    elif mode not in ("failed-write", "sidecar-save", "timeout"):
        assert writes == []


def test_native_slider_accessibility(tmp_path):
    binary = tmp_path / "slider-test"
    subprocess.run(["xcrun", "swiftc", "-parse-as-library", "-module-cache-path",
                    str(tmp_path / "modules"), str(ROOT / "Sources/OizysApp/OizysLogo.swift"),
                    str(ROOT / "Tests/Support/slider_test.swift"),
                    *flags(binary, swift=True), "-o", str(binary)], check=True, timeout=120)
    result = subprocess.run([str(binary)], capture_output=True, text=True, timeout=10)
    assert result.returncode == 0, result.stderr + result.stdout
    assert result.stdout.strip() == "PASS slider accessibility"


def test_display_tint_restoration(tmp_path):
    binary = tmp_path / "tint-test"
    subprocess.run(["xcrun", "swiftc", "-parse-as-library", "-module-cache-path",
                    str(tmp_path / "modules"), str(ROOT / "Sources/OizysApp/DisplayTint.swift"),
                    str(ROOT / "Tests/Support/display_tint_test.swift"),
                    *flags(binary, swift=True), "-o", str(binary)], check=True, timeout=120)
    result = subprocess.run([str(binary)], capture_output=True, text=True, timeout=10)
    assert result.returncode == 0, result.stderr
    assert result.stdout.strip() == "PASS display tint restoration"
