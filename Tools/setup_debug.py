"""Prepare an isolated developer Python environment and Firefox runtime. Runs no tests."""
from pathlib import Path
import os
import subprocess
import sys

ROOT = Path(__file__).resolve().parent.parent


def main():
    python = ROOT / ".venv/bin/python"
    if not python.exists():
        subprocess.run([sys.executable, "-m", "venv", str(ROOT / ".venv")], check=True)
    subprocess.run([str(python), "-m", "pip", "install", "--disable-pip-version-check",
                    "pytest", "hypothesis", "numpy", "yt-dlp", "playwright"], check=True)
    environment = dict(os.environ)
    environment["PLAYWRIGHT_BROWSERS_PATH"] = str(ROOT / "build/browsers")
    subprocess.run([str(python), "-m", "playwright", "install", "firefox"], env=environment, check=True)
    print("Developer dependencies ready. No tests or personal browsers were launched.")


if __name__ == "__main__":
    main()
