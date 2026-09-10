"""Exercise SidecarAuto's notification lifecycle without touching a real iPad."""
from pathlib import Path
import platform
import subprocess

import pytest

ROOT = Path(__file__).resolve().parent.parent


@pytest.mark.skipif(platform.system() != "Darwin", reason="Sidecar is macOS-only")
def test_sidecar_observes_devices_after_unavailable_start(tmp_path):
    subprocess.run(
        [
            "xcrun",
            "swiftc",
            "-parse-as-library",
            "-module-cache-path",
            str(tmp_path / "modules"),
            str(ROOT / "Sources/OizysApp/SidecarAuto.swift"),
            str(ROOT / "Tests/Support/sidecar_auto_test.swift"),
            "-o",
            str(tmp_path / "sidecar-auto-test"),
        ],
        check=True,
    )
    result = subprocess.run([str(tmp_path / "sidecar-auto-test")], capture_output=True, text=True, check=True)
    assert result.stdout.strip() == "PASS sidecar auto"
