"""Compile the production CGRect conversion and exercise malformed metadata."""
import subprocess

from Support import oizyscore as core
from Support.native_coverage import flags


def test_dirty_rect_conversion_is_bounded(tmp_path):
    source = tmp_path / "capture_geometry.swift"
    source.write_text((core.ROOT / "Sources/OizysPlatform/Capture.swift").read_text() + r'''

func check(_ rect: CGRect, _ expectedCount: Int) {
    let info: [SCStreamFrameInfo: Any] = [.dirtyRects: [rect.dictionaryRepresentation as Any]]
    precondition(dirtyRects(info).count == expectedCount)
}
check(CGRect(x: 1.25, y: 2.5, width: 3.75, height: 4.5), 1)
check(.zero, 0)
check(CGRect(x: 1, y: 2, width: -3, height: 4), 0)
check(CGRect(x: -1, y: 0, width: 1, height: 1), 0)
check(CGRect(x: CGFloat(Double.nan), y: 0, width: 1, height: 1), 0)
check(CGRect(x: CGFloat(Double.infinity), y: 0, width: 1, height: 1), 0)
check(CGRect(x: 0, y: 0, width: CGFloat(UInt32.max) + 1, height: 1), 0)
let valid = CGRect(x: 1.25, y: 2.5, width: 3.75, height: 4.5).dictionaryRepresentation
let converted = dirtyRects([.dirtyRects: [valid as Any]])[0]
precondition(converted.x == 1 && converted.y == 2 && converted.w == 4 && converted.h == 5)
let invalid = CGRect(x: 0, y: 0, width: Double.infinity, height: 1).dictionaryRepresentation
precondition(dirtyRects([.dirtyRects: [valid as Any, invalid as Any]]).isEmpty)
''')
    binary = tmp_path / "capture-geometry"
    command = ["xcrun", "swiftc", "-Xcc", "-I", "-Xcc",
               str(core.ROOT / "Sources/OizysCore/include"), "-import-objc-header",
               str(core.ROOT / "Sources/OizysPlatform/Bridge.h"),
               *flags(binary, swift=True), str(source), "-o", str(binary),
               "-L", str(core.LIBRARY_PATH.parent), "-lOizysCore",
               "-Xlinker", "-rpath", "-Xlinker", str(core.LIBRARY_PATH.parent),
               "-framework", "ScreenCaptureKit", "-framework", "CoreMedia",
               "-framework", "CoreVideo", "-framework", "CoreGraphics"]
    subprocess.run(command, cwd=core.ROOT, check=True, capture_output=True, text=True)
    subprocess.run([str(binary)], check=True, capture_output=True, text=True)
