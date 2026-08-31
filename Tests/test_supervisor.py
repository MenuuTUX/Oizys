"""Exercise crash/reconnect/timeout supervision using real child processes, no dock."""
import os
import pathlib
import signal
import subprocess
import sys
import time
from contextlib import contextmanager

import pytest

ROOT = pathlib.Path(__file__).resolve().parent.parent


@pytest.fixture(scope="module")
def supervisor(tmp_path_factory):
    output = tmp_path_factory.mktemp("supervisor") / "supervisor-test"
    subprocess.run([
        "xcrun", "clang", "-std=c11", "-Wall", "-Wextra", "-Werror",
        "-I", str(ROOT / "Sources/OizysCore/include"),
        str(ROOT / "Tests/Support/supervisor_test.c"), "-o", str(output),
    ], check=True, capture_output=True, text=True)
    return output


def eventually(predicate, seconds=8):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        if predicate():
            return
        time.sleep(0.05)
    assert predicate(), "supervisor did not reach the expected state in time"


@contextmanager
def service(supervisor, directory, vendor=False, topology=1, stubborn=False):
    worker = directory / "worker"
    worker.write_text(f"#!{sys.executable}\n" + '''
import os, pathlib, signal, time
pidfile = pathlib.Path(os.environ["OIZYS_TEST_PIDS"])
with pidfile.open("a") as out:
    out.write(str(os.getpid()) + "\\n")
if os.environ.get("OIZYS_TEST_STUBBORN") and len(pidfile.read_text().splitlines()) == 1:
    signal.signal(signal.SIGTERM, signal.SIG_IGN)
fd = int(next(arg.split("=", 1)[1] for arg in __import__("sys").argv if arg.startswith("--worker-fd=")))
while True:
    os.write(fd, b".")
    time.sleep(0.1)
''')
    worker.chmod(0o700)
    topology_file = directory / "topology"
    topology_file.write_text(str(topology))
    pids = directory / "pids"
    pids.write_text("")
    env = dict(os.environ, OIZYS_TEST_DIR=str(directory) + "/",
               OIZYS_TEST_TOPOLOGY=str(topology_file), OIZYS_TEST_PIDS=str(pids))
    if stubborn:
        env["OIZYS_TEST_STUBBORN"] = "1"
    if vendor:
        env["OIZYS_TEST_VENDOR"] = "1"
    logfile = directory / "service.log"
    with logfile.open("w") as log:
        process = subprocess.Popen([str(supervisor), str(worker)], env=env, stdout=log,
                                   stderr=subprocess.STDOUT, start_new_session=True)
        try:
            yield process, logfile, pids, topology_file, env, worker
        finally:
            if process.poll() is None:
                process.terminate()
                process.wait(timeout=13)
    for pid in pids.read_text().splitlines():
        with pytest.raises(ProcessLookupError):
            os.kill(int(pid), 0)


def test_crash_restarts_oizys_and_restores_vendor_only_on_stop(supervisor, tmp_path):
    with service(supervisor, tmp_path, vendor=True) as (process, log, pids, _, _, _):
        eventually(lambda: "worker ready" in log.read_text())
        os.kill(int(pids.read_text().splitlines()[-1]), signal.SIGKILL)
        eventually(lambda: log.read_text().count("worker ready") == 2)
        assert process.poll() is None
        assert "vendor restore" not in log.read_text()
    assert log.read_text().count("TEST vendor restore") == 1


def test_absent_ambiguous_and_reconnected_dock(supervisor, tmp_path):
    with service(supervisor, tmp_path, topology=0) as (process, log, pids, topology, _, _):
        eventually(lambda: "waiting for one supported" in log.read_text())
        assert not pids.read_text()
        topology.write_text("2")
        time.sleep(1.2)
        assert not pids.read_text(), "ambiguous device sets must not be seized"
        topology.write_text("1")
        eventually(lambda: "worker ready" in log.read_text())
        topology.write_text("0")
        os.kill(int(pids.read_text().splitlines()[-1]), signal.SIGKILL)
        eventually(lambda: log.read_text().count("waiting for one supported") == 2)
        assert len(pids.read_text().splitlines()) == 1
        topology.write_text("1")
        eventually(lambda: log.read_text().count("worker ready") == 2)
        assert process.poll() is None
    assert "TEST vendor restore" not in log.read_text()


def test_duplicate_service_does_not_touch_vendor_or_worker(supervisor, tmp_path):
    with service(supervisor, tmp_path) as (_, log, pids, _, env, worker):
        eventually(lambda: "worker ready" in log.read_text())
        duplicate = subprocess.run([str(supervisor), str(worker)], env=env,
                                   capture_output=True, text=True, timeout=3)
        assert duplicate.returncode == 1
        assert "another Oizys service" in duplicate.stderr
        assert "TEST vendor" not in duplicate.stdout
        assert len(pids.read_text().splitlines()) == 1


def test_unresponsive_worker_is_reaped_before_restart(supervisor, tmp_path):
    with service(supervisor, tmp_path, stubborn=True) as (process, log, pids, _, _, _):
        eventually(lambda: "worker ready" in log.read_text())
        hung = int(pids.read_text().splitlines()[-1])
        os.kill(hung, signal.SIGSTOP)
        eventually(lambda: log.read_text().count("worker ready") == 2, seconds=30)
        assert "stopped responding" in log.read_text()
        assert "did not stop in 10 seconds" in log.read_text()
        assert process.poll() is None
        with pytest.raises(ProcessLookupError):
            os.kill(hung, 0)
