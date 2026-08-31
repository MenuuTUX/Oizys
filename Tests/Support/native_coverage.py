"""Include independently compiled native test binaries in the coverage report."""
import os
from pathlib import Path


def flags(output, swift=False):
    directory = os.environ.get("OIZYS_COVERAGE_DIR")
    if not directory:
        return []
    with (Path(directory) / "objects.txt").open("a") as objects:
        objects.write(str(output) + "\n")
    return (["-profile-generate", "-profile-coverage-mapping"] if swift else
            ["-fprofile-instr-generate", "-fcoverage-mapping"])
