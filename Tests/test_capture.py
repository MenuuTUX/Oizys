"""The capture queue must stay bounded when the encoder is slower than the producer."""
import ctypes
import pathlib
import subprocess

from Support import mviewcore as core

ROOT = pathlib.Path(__file__).resolve().parent.parent


def test_capture_keeps_latest_frame_and_drops_pending_work_on_shutdown(tmp_path):
    output = tmp_path / "capture-tests.dylib"
    command = ["xcrun", "clang++", "-std=c++20", "-fobjc-arc", "-dynamiclib",
               "-I", str(ROOT / "Sources/MViewCore/include"),
               str(ROOT / "Tests/Support/capture_test.mm"), str(core.LIBRARY_PATH),
               "-o", str(output)]
    for framework in ("Foundation", "CoreGraphics", "CoreMedia", "CoreVideo", "ScreenCaptureKit",
                      "ImageIO", "UniformTypeIdentifiers"):
        command += ["-framework", framework]
    result = subprocess.run(command, capture_output=True, text=True)
    assert result.returncode == 0, result.stderr
    library = ctypes.CDLL(str(output))
    library.test_capture_queue.restype = ctypes.c_int
    assert library.test_capture_queue() == 0
