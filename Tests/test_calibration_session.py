"""The phone transport assembles bounded requests and rejects bad measurements."""
from pathlib import Path
import hashlib
import http.client
import json
import os
import select
import socket
import ssl
import subprocess
import sys
import time
from urllib.parse import urlsplit

import pytest

from Support.native_coverage import flags

ROOT = Path(__file__).resolve().parent.parent


@pytest.fixture(scope="module")
def binary(tmp_path_factory):
    tmp_path = tmp_path_factory.mktemp("calibration-session")
    binary = tmp_path / "calibration-session-test"
    subprocess.run(["xcrun", "swiftc", "-parse-as-library", "-module-cache-path",
                    str(tmp_path / "modules"),
                    str(ROOT / "Sources/OizysApp/CalibrationSession.swift"),
                    str(ROOT / "Tests/Support/calibration_session_test.swift"),
                    *flags(binary, swift=True), "-o", str(binary)], check=True, timeout=120)
    return binary


def test_calibration_session(binary):
    result = subprocess.run([str(binary)], capture_output=True, text=True, timeout=10)
    assert result.returncode == 0, result.stderr
    assert result.stdout.strip() == "PASS calibration session"


def test_solver_stages_correction_before_session_can_save(binary, tmp_path):
    config = tmp_path / "config.json"
    active = tmp_path / "calibration.json"
    active.write_text("active correction")
    driver = tmp_path / "solver"
    driver.write_text("#!" + sys.executable + "\n" + '''
from pathlib import Path
import os
import sys
assert sys.argv[1:3] == ["calibrate", "run"]
config = Path(os.environ["OIZYS_CONFIG_PATH"])
assert config.parent == Path(sys.argv[3]).parent
config.with_name("calibration.json").write_text("new correction")
print("staged")
''')
    driver.chmod(0o700)
    result = subprocess.run([str(binary), "--staged-solver", str(driver)],
                            env=dict(os.environ, OIZYS_CONFIG_PATH=str(config)),
                            capture_output=True, text=True, timeout=15)
    assert result.returncode == 0, result.stderr
    assert result.stdout.strip() == "PASS staged solver"
    assert active.read_text() == "active correction"


def test_calibration_undo_restores_prior_file_and_preserves_newer_changes(binary, tmp_path):
    result = subprocess.run([str(binary), "--undo", str(tmp_path)],
                            capture_output=True, text=True, timeout=10)
    assert result.returncode == 0, result.stderr
    assert result.stdout.strip() == "PASS calibration undo"


def test_cancel_after_solver_starts_and_undo_after_completed_save(binary, tmp_path):
    driver = tmp_path / "solver"
    driver.write_text("#!" + sys.executable + "\n" + '''
from pathlib import Path
import os, time
folder = Path(__file__).parent
(folder / "started").touch()
time.sleep(0.2)
Path(os.environ["OIZYS_CONFIG_PATH"]).with_name("calibration.json").write_text("new correction")
(folder / "finished").touch()
print("staged")
''')
    driver.chmod(0o700)
    result = subprocess.run([str(binary), "--save-cancel", str(driver), str(tmp_path)],
                            capture_output=True, text=True, timeout=15)
    assert result.returncode == 0, result.stderr
    assert result.stdout.strip() == "PASS calibration save, cancel and undo"


def test_tls_routes_restart_and_certificate_renewal(binary, tmp_path):
    fingerprints = []
    for attempt in range(3):
        if attempt == 2:
            expired = time.time() - 365 * 86400
            os.utime(tmp_path / "calibration-identity.p12", (expired, expired))
        process = subprocess.Popen([str(binary), "--serve", str(tmp_path)], stdin=subprocess.PIPE,
                                   stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        try:
            assert select.select([process.stdout], [], [], 10)[0], "TLS listener did not become ready"
            info = json.loads(process.stdout.readline())
            url = urlsplit(info["address"])
            # First inspect the certificate, then trust that exact certificate for all
            # route checks. Hostname verification proves the IP SAN is present.
            with socket.create_connection((url.hostname, url.port), timeout=5) as raw:
                with ssl._create_unverified_context().wrap_socket(raw, server_hostname=url.hostname) as tls:
                    certificate = tls.getpeercert(binary_form=True)
            fingerprint = ":".join(f"{byte:02X}" for byte in hashlib.sha256(certificate).digest())
            assert fingerprint == info["fingerprint"]
            fingerprints.append(fingerprint)
            context = ssl.create_default_context(cadata=ssl.DER_cert_to_PEM_cert(certificate))

            def request(method, path, body=None):
                connection = http.client.HTTPSConnection(url.hostname, url.port, context=context, timeout=5)
                try:
                    connection.request(method, path, body)
                    response = connection.getresponse()
                    return response.status, response.getheader("Location"), response.read()
                finally:
                    connection.close()

            status, session_path, _ = request("GET", url.path)
            assert status == 303 and session_path != url.path
            assert request("GET", url.path)[0] == 404, "QR token was reusable"
            assert request("GET", session_path + "extra")[0] == 404
            for _ in range(2):
                status, _, page = request("GET", session_path)
                assert status == 200 and (session_path + "/reading").encode() in page
            assert request("POST", session_path + "/reading", "{}")[0] == 410
            with socket.create_connection((url.hostname, url.port), timeout=5) as raw:
                with context.wrap_socket(raw, server_hostname=url.hostname) as tls:
                    tls.sendall(f"GET {session_path} HTTP/1.1\r\nHost:".encode())
                    time.sleep(0.02)
                    tls.sendall(b" local\r\n\r\n")
                    assert tls.recv(4096).startswith(b"HTTP/1.1 200")
            process.stdin.write("terminate\n" if attempt == 1 else "stop\n")
            process.stdin.flush()
            assert process.communicate(timeout=5)[0].strip() == "STOPPED"
            assert process.returncode == 0
            with pytest.raises(OSError):
                socket.create_connection((url.hostname, url.port), timeout=1)
        finally:
            if process.poll() is None:
                process.kill()
                process.communicate()
    assert fingerprints[0] == fingerprints[1], "Certificate changed across sessions"
    assert fingerprints[2] != fingerprints[1], "Certificate renewal did not run"
