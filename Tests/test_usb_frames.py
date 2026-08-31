"""Frame boundaries and short-transfer failures at the IOUSBHost boundary."""
import ctypes
import pathlib
import subprocess

from Support import oizyscore as core

ROOT = pathlib.Path(__file__).resolve().parent.parent


def test_whole_frames_and_short_writes(tmp_path):
    output = tmp_path / "usb-frame-tests.dylib"
    result = subprocess.run([
        "xcrun", "clang", "-std=c11", "-fblocks", "-dynamiclib",
        "-I", str(ROOT / "Sources/OizysCore/include"),
        str(ROOT / "Tests/Support/usb_frame_test.c"), str(core.LIBRARY_PATH),
        "-framework", "Foundation", "-framework", "IOKit", "-framework", "IOUSBHost",
        "-o", str(output),
    ], capture_output=True, text=True)
    assert result.returncode == 0, result.stderr
    library = ctypes.CDLL(str(output))
    library.test_usb_frames.restype = ctypes.c_int
    assert library.test_usb_frames() == 0
