"""Exercise the real driver's unchanged-frame power policy without a dock."""
import subprocess

from Support import oizyscore as core
from Support.native_coverage import flags


def test_unchanged_capture_reaches_idle_rate(tmp_path):
    binary = tmp_path / "driver-idle-test"
    command = ["xcrun", "clang", "-std=c11", "-fblocks", "-O0", *flags(binary),
               "-I", str(core.ROOT / "Sources/OizysCore/include"),
               str(core.ROOT / "Tests/Support/driver_idle_test.c"),
               str(core.LIBRARY_PATH), "-framework", "CoreFoundation",
               "-framework", "Security", "-framework", "IOKit",
               "-framework", "IOSurface", "-framework", "CoreGraphics",
               "-framework", "ImageIO", "-lpthread",
               "-Wl,-rpath," + str(core.LIBRARY_PATH.parent), "-o", str(binary)]
    subprocess.run(command, cwd=core.ROOT, check=True, capture_output=True, text=True)
    subprocess.run([str(binary)], check=True, capture_output=True, text=True)
