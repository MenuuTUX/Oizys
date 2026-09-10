"""Diagnostic logs stay bounded across repeated CLI sessions."""

import ctypes

from Support import oizyscore as core


def test_oversized_log_is_truncated_on_open(tmp_path):
    path = tmp_path / "run.log"
    path.write_bytes(b"x" * (4 * 1024 * 1024))
    core.lib.oizys_log_open.argtypes = [ctypes.c_char_p]
    core.lib.oizys_log.argtypes = [ctypes.c_char_p]
    core.lib.oizys_log_open(str(path).encode())
    core.lib.oizys_log(b"new session")
    core.lib.oizys_log_open(None)
    assert path.read_text().endswith("new session\n")
    assert path.stat().st_size < 100
