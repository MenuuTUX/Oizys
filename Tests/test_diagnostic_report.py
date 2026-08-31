"""Native exports preserve raw evidence and do not fabricate missing samples."""
from pathlib import Path
import subprocess

from Support.native_coverage import flags

ROOT = Path(__file__).resolve().parent.parent


def test_diagnostic_report(tmp_path):
    binary = tmp_path / "report-test"
    subprocess.run(["xcrun", "swiftc", "-parse-as-library", "-module-cache-path",
                    str(tmp_path / "modules"), str(ROOT / "Sources/OizysApp/DiagnosticReport.swift"),
                    str(ROOT / "Tests/Support/diagnostic_report_test.swift"),
                    *flags(binary, swift=True), "-o", str(binary)], check=True)
    result = subprocess.run([str(binary), str(tmp_path)], capture_output=True, text=True, timeout=10)
    assert result.returncode == 0, result.stderr
    assert result.stdout.strip() == "PASS diagnostic report"
