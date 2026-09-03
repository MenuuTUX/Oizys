"""Disposable run data. Settings, installed tools and system logs are out of scope."""
from contextvars import ContextVar
import fcntl
import os
from pathlib import Path
import re
import shutil
import stat
import subprocess
import tempfile

CURRENT = ContextVar("fixture_runtime", default=None)
RUN_NAME = re.compile(r"oizys-fixture-run-([0-9]+)-[a-zA-Z0-9_]+")


class CleanupError(RuntimeError):
    pass


def alive(pid):
    if pid <= 1:
        return True
    try:
        os.kill(pid, 0)
        return True
    except ProcessLookupError:
        return False
    except PermissionError:
        return True


def owned_directory(path):
    info = path.lstat()
    return stat.S_ISDIR(info.st_mode) and info.st_uid == os.getuid()


def cleanup_abandoned(base):
    removed = 0
    for path in base.glob("oizys-fixture-run-*"):
        match = RUN_NAME.fullmatch(path.name)
        try:
            if not match or not owned_directory(path) or alive(int(match[1])):
                continue
            # Children inherit this lease, so an orphan still using the folder is protected.
            try:
                descriptor = os.open(path / ".lease", os.O_RDWR | os.O_NOFOLLOW)
            except FileNotFoundError:
                # The owner died before it could create its lease or launch children.
                if path.exists():
                    shutil.rmtree(path)
                    removed += 1
                continue
            try:
                try:
                    fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
                except BlockingIOError:
                    continue
                shutil.rmtree(path)
                removed += 1
            finally:
                os.close(descriptor)
        except FileNotFoundError:
            continue
        except OSError:
            raise CleanupError("Could not remove abandoned temporary run data. The test was not started.") from None
    # Older builds used a browser-only folder. Never remove one referenced by a live process.
    legacy = list(base.glob("oizys-fixture-browser-*"))
    if legacy:
        commands = subprocess.check_output(["ps", "-U", str(os.getuid()), "-o", "command="], text=True)
        for path in legacy:
            if "obscura" in commands or str(path) in commands:
                continue
            try:
                if owned_directory(path):
                    shutil.rmtree(path)
                    removed += 1
            except FileNotFoundError:
                continue
            except OSError:
                raise CleanupError("Could not remove old temporary browser data. The test was not started.") from None
    return removed


class RunWorkspace:
    def __init__(self, base=None):
        self.base = Path(base or tempfile.gettempdir())
        self.directory = None
        self.descriptor = None

    def __enter__(self):
        cleanup_abandoned(self.base)
        self.directory = Path(tempfile.mkdtemp(prefix=f"oizys-fixture-run-{os.getpid()}-", dir=self.base))
        try:
            self.descriptor = os.open(self.directory / ".lease", os.O_CREAT | os.O_EXCL | os.O_RDWR | os.O_NOFOLLOW, 0o600)
            fcntl.flock(self.descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
            self.token = CURRENT.set(self)
        except BaseException:
            if self.descriptor is not None:
                os.close(self.descriptor)
            shutil.rmtree(self.directory)
            raise
        return self

    def environment(self, environment):
        result = dict(environment)
        # Diagnostic environment settings can otherwise write network/session data.
        for key in ("SSLKEYLOGFILE", "MOZ_LOG", "MOZ_LOG_FILE", "CFNETWORK_DIAGNOSTICS"):
            result.pop(key, None)
        result.update(TMPDIR=str(self.directory), TMP=str(self.directory), TEMP=str(self.directory),
                      XDG_CACHE_HOME=str(self.directory / "cache"), PYTHONDONTWRITEBYTECODE="1",
                      MOZ_CRASHREPORTER_DISABLE="1")
        return result

    def __exit__(self, *_):
        CURRENT.reset(self.token)
        try:
            shutil.rmtree(self.directory)
            if self.directory.exists():
                raise OSError()
        except OSError:
            raise CleanupError("Temporary run data could not be fully removed. Cleanup will be retried before the next test.") from None
        finally:
            os.close(self.descriptor)
        print("Temporary run data removed. Settings and installed tools were kept.", flush=True)
