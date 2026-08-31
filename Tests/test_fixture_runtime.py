"""Cleanup tests use disposable directories and processes, never user browser data."""
import fcntl
import os
from pathlib import Path
import signal
import subprocess
import sys

import pytest

TOOLS = Path(__file__).resolve().parents[1] / "Tools"
sys.path.insert(0, str(TOOLS))
import fixture
import fixture_runtime as runtime


@pytest.mark.parametrize("failure", [None, ValueError, KeyboardInterrupt])
def test_workspace_removes_run_data_on_every_exit(tmp_path, failure):
    settings = tmp_path / "fixture.json"
    settings.write_bytes(b"encrypted settings stay")
    def execute():
        with runtime.RunWorkspace(tmp_path) as run:
            assert run.directory.stat().st_mode & 0o777 == 0o700
            (run.directory / "cache").mkdir()
            (run.directory / "cache/session").write_bytes(b"disposable session")
            if failure:
                raise failure()
    if failure:
        with pytest.raises(failure):
            execute()
    else:
        execute()
    assert list(tmp_path.iterdir()) == [settings]
    assert settings.read_bytes() == b"encrypted settings stay"
    assert runtime.CURRENT.get() is None


def test_reap_only_inactive_owned_run_folders(tmp_path, monkeypatch):
    monkeypatch.setattr(runtime, "alive", lambda pid: pid == 10)
    inactive = tmp_path / "oizys-fixture-run-20-dead"
    active = tmp_path / "oizys-fixture-run-10-live"
    locked = tmp_path / "oizys-fixture-run-30-child"
    incomplete = tmp_path / "oizys-fixture-run-50-incomplete"
    incomplete.mkdir()
    unrelated = tmp_path / "personal-data"
    for folder in (inactive, active, locked, unrelated):
        folder.mkdir()
        (folder / ".lease").touch()
        (folder / "data").write_text("keep unless inactive")
    link = tmp_path / "oizys-fixture-run-40-link"
    link.symlink_to(unrelated, target_is_directory=True)
    with (locked / ".lease").open("r+") as lease:
        fcntl.flock(lease, fcntl.LOCK_EX | fcntl.LOCK_NB)
        assert runtime.cleanup_abandoned(tmp_path) == 2
    assert not inactive.exists()
    assert not incomplete.exists()
    assert all(folder.exists() for folder in (active, locked, unrelated, link))


def test_child_temp_files_and_diagnostics_stay_in_disposable_folder(tmp_path, monkeypatch):
    monkeypatch.setenv("SSLKEYLOGFILE", str(tmp_path / "must-not-write"))
    with runtime.RunWorkspace(tmp_path) as run:
        code = f"import os,tempfile; os.fstat({run.descriptor}); assert 'SSLKEYLOGFILE' not in os.environ; assert os.environ['PYTHONDONTWRITEBYTECODE']=='1'; tempfile.NamedTemporaryFile(delete=False).write(b'temporary')"
        fixture.run_child([sys.executable, "-c", code], check=True)
        assert len(list(run.directory.iterdir())) > 1
    assert not list(tmp_path.iterdir())


def test_cleanup_failure_is_reported_without_false_success(tmp_path, monkeypatch, capsys):
    run = runtime.RunWorkspace(tmp_path)
    run.__enter__()
    original = runtime.shutil.rmtree
    def denied(_):
        raise PermissionError("private path must not be printed")
    monkeypatch.setattr(runtime.shutil, "rmtree", denied)
    try:
        with pytest.raises(runtime.CleanupError, match="could not be fully removed") as error:
            run.__exit__(None, None, None)
        assert "private path" not in str(error.value)
        assert "Temporary run data removed" not in capsys.readouterr().out
    finally:
        original(run.directory)


def test_preflight_failure_prevents_playback(tmp_path, monkeypatch):
    def denied(_):
        raise runtime.CleanupError("Could not remove abandoned temporary run data. The test was not started.")
    monkeypatch.setattr(runtime, "cleanup_abandoned", denied)
    monkeypatch.setattr(fixture, "prepare_clips", lambda *a: pytest.fail("playback should not start"))
    with pytest.raises(fixture.FixtureError, match="test was not started"):
        fixture.run_fixture("unused", "unused", 2, 5, False, .5)


@pytest.mark.parametrize("number", [signal.SIGINT, signal.SIGTERM, signal.SIGKILL])
def test_interrupted_run_cleanup_and_next_run_recovery(tmp_path, number):
    code = f"""import sys,time,signal
sys.path.insert(0, {str(TOOLS)!r})
from fixture_runtime import RunWorkspace
def stop(*args):
    raise KeyboardInterrupt()
signal.signal(signal.SIGTERM, stop)
try:
    with RunWorkspace({str(tmp_path)!r}) as run:
        (run.directory / 'session').write_bytes(b'disposable')
        print('ready', flush=True)
        time.sleep(60)
except KeyboardInterrupt:
    pass
"""
    child = subprocess.Popen([sys.executable, "-u", "-c", code], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    try:
        assert child.stdout.readline().strip() == "ready"
        child.send_signal(number)
        child.communicate(timeout=5)
        if number == signal.SIGKILL:
            assert len(list(tmp_path.iterdir())) == 1
            with runtime.RunWorkspace(tmp_path):
                assert len(list(tmp_path.iterdir())) == 1
        assert not list(tmp_path.iterdir())
    finally:
        if child.poll() is None:
            child.kill()
        child.wait()
