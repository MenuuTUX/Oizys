"""Exercise the native permission policy without reading or resetting real TCC data."""
from pathlib import Path
import subprocess
import sys

import pytest
from Support.native_coverage import flags

ROOT = Path(__file__).resolve().parent.parent


@pytest.fixture(scope="module")
def permission_test(tmp_path_factory):
    if sys.platform != "darwin":
        pytest.skip("Native macOS permission policy")
    directory = tmp_path_factory.mktemp("debug-permissions")
    binary = directory / "test"
    subprocess.run(["xcrun", "swiftc", "-parse-as-library", "-module-cache-path", str(directory / "modules"),
                    str(ROOT / "Sources/OizysApp/DebugPermissions.swift"),
                    str(ROOT / "Tests/Support/debug_permissions_test.swift"),
                    *flags(binary, swift=True), "-o", str(binary)], check=True)
    return binary


@pytest.mark.parametrize("mode", ["preserve", "production", "order", "repeat", "failure", "unregistered",
                                 "quit", "quit-production", "quit-shared", "quit-restart", "quit-failure"])
def test_debug_permission_policy(permission_test, mode):
    result = subprocess.run([str(permission_test), mode], capture_output=True, text=True, timeout=10)
    assert result.returncode == 0, result.stderr
    assert result.stdout.strip() == "PASS " + mode
