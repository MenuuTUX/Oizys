"""Verify restart targeting without stopping apps or changing system services."""
import importlib.util
import json
from pathlib import Path
import plistlib
import signal

import pytest

spec = importlib.util.spec_from_file_location("debug_session", Path(__file__).resolve().parents[1] / "Tools/debug_session.py")
session = importlib.util.module_from_spec(spec)
spec.loader.exec_module(session)


def app(directory, variant="debug-verbose", identifier=None):
    bundle = directory / "Oizys-debug.app"
    (bundle / "Contents/MacOS").mkdir(parents=True)
    (bundle / "Contents/Info.plist").write_bytes(plistlib.dumps({
        "CFBundleIdentifier": identifier or "org.oizys.Oizys." + variant,
        "OizysVariant": variant,
    }))
    return str(bundle / "Contents/MacOS/Oizys-debug")


def test_restart_selects_only_this_checkouts_variant_or_portable_cache(tmp_path):
    root, cache = tmp_path / "repo", tmp_path / "cache"
    yes = [app(root / "build/DebugVerbose"), app(root / "build/apps/debug-verbose/0.3.0"), app(cache / "revision")]
    no = [app(root / "build/DebugMinimal", "debug-minimal"), app(tmp_path / "other-repo/build"),
          app(root / "build/wrong", identifier="org.oizys.Oizys.production"),
          "/Applications/Oizys.app/Contents/MacOS/Oizys", yes[0].replace("MacOS/Oizys-debug", "MacOS/OizysDriver")]
    assert all(session.selected_app(path, root, "debug-verbose", cache) for path in yes)
    assert not any(session.selected_app(path, root, "debug-verbose", cache) for path in no)


def test_signaling_rechecks_executable_before_using_pid(monkeypatch):
    monkeypatch.setattr(session, "processes", lambda: {12: (1, "/different/program"), 13: (1, "/debug")})
    sent = []
    monkeypatch.setattr(session.os, "kill", lambda *args: sent.append(args))
    session.signal_matching({12: "/old/debug", 13: "/debug", 14: "/gone"}, signal.SIGTERM)
    assert sent == [(13, signal.SIGTERM)]


@pytest.mark.parametrize("variant", ["production", "production-fallback", "unknown"])
def test_restart_rejects_production_before_reading_processes(monkeypatch, variant):
    monkeypatch.setattr(session, "processes", lambda: pytest.fail("unexpected process scan"))
    with pytest.raises(ValueError):
        session.stop_debug(Path("/repo"), variant)


@pytest.mark.parametrize("stuck", [False, True])
@pytest.mark.parametrize("lease_owner", [None, 10, 90])
def test_shutdown_preserves_production_and_other_debug_sessions(monkeypatch, tmp_path, stuck, lease_owner):
    monkeypatch.setattr(session.Path, "home", lambda: tmp_path)
    root = tmp_path / "repo"
    selected = app(root / "build/DebugVerbose")
    other = app(root / "build/DebugMinimal", "debug-minimal")
    production = "/Applications/Oizys.app/Contents/MacOS/Oizys"
    snapshot = {10: (1, selected), 11: (10, "/tool/python"), 12: (11, "/tool/helper"),
                20: (1, production), 21: (20, "/Applications/Oizys.app/Contents/MacOS/OizysDriver"),
                30: (1, other), 31: (30, "/other/helper")}
    if lease_owner:
        lease = tmp_path / "Library/Application Support/Oizys/development-session.json"
        lease.parent.mkdir(parents=True)
        lease.write_text(json.dumps({"pid": lease_owner, "resume": True}))
    monkeypatch.setattr(session, "processes", lambda: snapshot)
    sent, recovered = [], []
    monkeypatch.setattr(session, "signal_matching", lambda targets, sig: sent.append((set(targets), sig)))
    waits = iter([{}, {10: selected, 11: "/tool/python", 12: "/tool/helper"} if stuck else {},
                  {10: selected} if stuck else {}, {}])
    monkeypatch.setattr(session, "wait_for_exit", lambda *a: next(waits))
    monkeypatch.setattr(session.subprocess, "run", lambda args, **kw: recovered.append(args))
    session.stop_debug(root, "debug-verbose")
    assert sent[0] == ({10}, signal.SIGTERM)
    assert all(targets <= {10, 11, 12} for targets, _ in sent)
    assert any(sig == signal.SIGKILL for _, sig in sent) == stuck
    assert bool(recovered) == (lease_owner == 10)
    assert all(args[1:] == ["service", "recover-debug"] for args in recovered)
