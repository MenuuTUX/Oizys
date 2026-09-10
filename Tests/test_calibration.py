"""The calibration self-test must stay clean under the real native library."""

from Support import oizyscore as core


def test_calibration_selftest_passes():
    assert core.lib.oizys_calibration_selftest() == 0
