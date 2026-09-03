"""Local, opt-in fixtures. This module is never packaged with the app."""
from __future__ import annotations

import argparse
import base64
import getpass
import hashlib
import json
import math
import os
from pathlib import Path
import re
import resource
import shutil
import signal
import subprocess
import sys
import tempfile
import time
import uuid
from urllib.parse import urlparse

from fixture_runtime import CURRENT, CleanupError, RunWorkspace

ROOT = Path(__file__).resolve().parent.parent
SOURCE = ROOT / "Tools/FixtureBench.swift"
SETTINGS = Path.home() / "Library/Application Support/Oizys/fixture.json"
MAX_CLIPS = 96


class FixtureError(RuntimeError):
    """A fixed, user-safe message with no source URL or child-process output."""


class FixtureInputError(ValueError, FixtureError):
    pass


class FixtureUnlockError(FixtureError):
    pass
MEDIA_HOSTS = ("cdninstagram.com", "fbcdn.net", "tiktok.com", "tiktokcdn.com")


def stop_child(process):
    # Each operation owns its process group. Kill only this run's children, including
    # compiler/resolver grandchildren, even if the group leader has already exited.
    try:
        os.killpg(process.pid, signal.SIGTERM)
    except ProcessLookupError:
        pass
    except PermissionError:
        # WebKit may leave sandboxed XPC services in the former process group. They
        # are managed by macOS; still stop our own executable if it has not exited.
        if process.poll() is None:
            process.terminate()
    try:
        process.wait(timeout=1)
    except subprocess.TimeoutExpired:
        pass
    finally:
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        except PermissionError:
            if process.poll() is None:
                process.kill()
        process.wait()


def run_child(command, *, input=None, capture_output=False, text=False,
              timeout=None, check=False, **kwargs):
    if workspace := CURRENT.get():
        kwargs["env"] = workspace.environment(kwargs.get("env", os.environ))
        kwargs["pass_fds"] = (*kwargs.get("pass_fds", ()), workspace.descriptor)
    if capture_output:
        kwargs.update(stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    process = subprocess.Popen(command, stdin=subprocess.PIPE if input is not None else None,
                               text=text, start_new_session=True, **kwargs)
    try:
        stdout, stderr = process.communicate(input, timeout=timeout)
        result = subprocess.CompletedProcess(command, process.returncode, stdout, stderr)
        if check:
            result.check_returncode()
        return result
    finally:
        stop_child(process)


def build_player():
    directory = ROOT / "build/fixture"
    directory.mkdir(parents=True, exist_ok=True)
    binary = directory / "FixtureBench"
    if not binary.exists() or binary.stat().st_mtime_ns < SOURCE.stat().st_mtime_ns:
        # This source also rejects compilation without OIZYS_FIXTURE_DEBUG.
        with tempfile.TemporaryDirectory(prefix="compile-", dir=directory) as temporary:
            output = Path(temporary) / "FixtureBench"
            run_child(["xcrun", "swiftc", "-O", "-swift-version", "5",
                       "-D", "OIZYS_FIXTURE_DEBUG", "-module-cache-path",
                       str(ROOT / "build/ModuleCache"), str(SOURCE), "-o", str(output)],
                      check=True, cwd=ROOT)
            os.replace(output, binary)
    return binary


def invoke(binary, request):
    result = run_child([str(binary)], input=json.dumps(request).encode(),
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=30)
    if result.returncode == 3 and request.get("mode") == "open":
        raise FixtureUnlockError("Could not unlock these saved settings. Check the exact passphrase, including spaces and capitals. "
                                 "If you no longer have it, choose Set up again. Preparing tools will not change the passphrase.")
    if result.returncode:
        raise FixtureError("The local helper could not complete the request. Prepare required tools and retry; saved settings were not changed.")
    return result.stdout


def derive_key(passphrase, salt):
    if len(salt) != 16:
        raise FixtureInputError("Invalid fixture salt.")
    return hashlib.pbkdf2_hmac("sha256", passphrase.encode(), salt, 600_000, dklen=32)


def check_crypto(binary):
    """Verify the helper in its actual launch environment, without user settings."""
    key = base64.b64encode(os.urandom(32)).decode()
    expected = b"local unlock helper check"
    sealed = invoke(binary, dict(mode="seal", key=key, data=base64.b64encode(expected).decode()))
    result = invoke(binary, dict(mode="open", key=key, data=base64.b64encode(sealed).decode()))
    if result != expected:
        raise FixtureError("The local unlock helper failed its check. Prepare required tools and retry.")


def validate_source(value):
    value = value.strip()
    url = urlparse(value)
    if (url.scheme == "https" and not url.username and not url.password
            and url.port in (None, 443) and not url.query and not url.fragment):
        if (url.hostname in ("instagram.com", "www.instagram.com")
                and re.fullmatch(r"/[A-Za-z0-9_.]+(?:/reels)?/?", url.path)):
            return "https://www.instagram.com/" + url.path.strip("/").split("/")[0] + "/reels/"
        if (url.hostname in ("tiktok.com", "www.tiktok.com")
                and re.fullmatch(r"/@[A-Za-z0-9_.]+/?", url.path)):
            return "https://www.tiktok.com" + url.path.rstrip("/")
    raise FixtureInputError("Enter a supported HTTPS source profile URL without a query or fragment.")


def seal_settings(binary, path, source, passphrase, *, replace=False):
    source = validate_source(source)
    salt = os.urandom(16)
    sealed = invoke(binary, dict(mode="seal", key=base64.b64encode(
        derive_key(passphrase, salt)).decode(), data=base64.b64encode(source.encode()).decode()))
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    value = dict(version=1, salt=base64.b64encode(salt).decode(),
                 sealed=base64.b64encode(sealed).decode())
    if replace:
        # Caller must unlock first. Atomic replacement keeps the old setting intact
        # if the process is interrupted during the update.
        with tempfile.NamedTemporaryFile(mode="w", dir=path.parent, delete=False) as file:
            temporary = Path(file.name)
            try:
                json.dump(value, file)
                file.close()
                os.replace(temporary, path)
            finally:
                temporary.unlink(missing_ok=True)
        return
    # O_EXCL: initialization must never overwrite an existing key or settings file.
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(fd, "w") as file:
        json.dump(value, file)


def open_settings(binary, path, passphrase):
    if not passphrase:
        raise FixtureInputError("Enter your passphrase first.")
    try:
        data = json.loads(path.read_text())
        salt = base64.b64decode(data["salt"], validate=True)
        sealed = base64.b64decode(data["sealed"], validate=True)
        if data.get("version") != 1 or len(salt) != 16 or len(sealed) < 28:
            raise ValueError()
    except (OSError, ValueError, KeyError, TypeError):
        raise FixtureError("The saved settings file is incomplete or unsupported. Choose Set up again to create new settings and keep an encrypted backup.") from None
    key = derive_key(passphrase, salt)
    result = invoke(binary, dict(mode="open", key=base64.b64encode(key).decode(),
                                data=data["sealed"]))
    return validate_source(result.decode())


def replace_settings(binary, path, source, passphrase):
    """Explicit start-over: keep the old ciphertext; never decrypt it without its key."""
    if len(passphrase) < 16:
        raise FixtureInputError("Use a new passphrase of at least 16 characters.")
    original = path.read_bytes()
    with tempfile.TemporaryDirectory(prefix=".fixture-new-", dir=path.parent) as directory:
        replacement = Path(directory) / "settings.json"
        seal_settings(binary, replacement, source, passphrase)
        open_settings(binary, replacement, passphrase)
        backup = path.with_name("fixture-backup-" + uuid.uuid4().hex + ".json")
        fd = os.open(backup, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(fd, "wb") as output:
            output.write(original)
        if path.read_bytes() != original:
            raise FixtureError("Settings changed in another window. Close and reopen this window before trying again.")
        os.replace(replacement, path)
    return backup


# Obscura is the only browser this uses: one short-lived headless process per call, no
# profile, no personal browser, no vendor runtime to install. The page script below runs
# inside it and returns JSON; nothing else crosses back.
DISCOVER_JS = """(async () => {
  const found = [];
  const scrape = () => {
    for (const a of document.querySelectorAll('a[href]')) {
      let url; try { url = new URL(a.href); } catch { continue; }
      if (url.protocol !== 'https:') continue;
      if (!['www.instagram.com', 'instagram.com'].includes(url.hostname)) continue;
      const m = /^\\/(?:[A-Za-z0-9_.]+\\/)?reel\\/([A-Za-z0-9_-]+)\\/?$/.exec(url.pathname);
      const link = m && 'https://www.instagram.com/reel/' + m[1] + '/';
      if (link && !found.includes(link)) found.push(link);
    }
  };
  let stale = 0;
  for (let i = 0; i < 48 && found.length < COUNT && stale < 8; i++) {
    const before = found.length;
    scrape();
    stale = before === found.length ? stale + 1 : 0;
    window.scrollTo(0, document.body.scrollHeight);
    await new Promise(r => setTimeout(r, 1000));
  }
  scrape();
  return JSON.stringify({path: location.pathname, host: location.hostname,
                         agent: navigator.userAgent, links: found.slice(0, COUNT)});
})()"""

RESOLVE_JS = """(() => {
  const documents = [];
  for (const s of document.querySelectorAll('script[type="application/json"]')) {
    try { documents.push(JSON.parse(s.textContent)); } catch {}
  }
  return JSON.stringify({path: location.pathname, host: location.hostname,
                         agent: navigator.userAgent, documents});
})()"""


def obscura(url, script, timeout):
    """One headless page. Raises FixtureError; never forwards the browser's own text."""
    workspace = CURRENT.get()
    with tempfile.TemporaryDirectory(prefix="oizys-fixture-browser-",
                                     dir=workspace.directory if workspace else None) as temporary:
        result = run_child(["obscura", "--stealth", "scrape", url, "--eval", script,
                            "--format", "json", "--quiet", "--timeout", str(int(timeout))],
                           text=True, capture_output=True, timeout=timeout + 30,
                           env=dict(os.environ, TMPDIR=temporary, OBSCURA_STORAGE_DIR=temporary))
    if result.returncode:
        raise FixtureError("The isolated browser could not complete the request. Check your connection, "
                           "or install obscura with Prepare required tools. "
                           "Personal browsers were not accessed; saved settings were not changed.")
    try:
        page = json.loads(result.stdout)["results"][0]
        payload = json.loads(page["eval"])
    except (ValueError, KeyError, IndexError, TypeError):
        raise FixtureError("The isolated browser returned nothing readable for that source.") from None
    # The page may have redirected to a login or checkpoint wall. Treat that as no access
    # rather than parsing whatever the wall happened to contain.
    if (payload.get("host") not in ("www.instagram.com", "instagram.com")
            or payload.get("path", "").startswith(("/accounts/", "/challenge/", "/checkpoint/"))):
        raise FixtureError("The source did not expose enough playable public clips to the isolated browser. "
                           "It may require login or be limiting access. Try later or use another public source. "
                           "Your passphrase and display permissions do not need changing.")
    return payload


def media_from_documents(documents, shortcode, user_agent):
    """Use only metadata attached to this clip, never recommendations or page text."""
    pending = list(documents)
    while pending:
        node = pending.pop()
        if isinstance(node, list):
            pending.extend(node)
        elif isinstance(node, dict):
            if node.get("code", node.get("shortcode")) == shortcode:
                versions = node.get("video_versions", [])
                if not isinstance(versions, list):
                    continue
                versions = [v for v in versions if isinstance(v, dict)
                            and isinstance(v.get("url"), str) and allowed_media_url(v["url"])]
                def area(version):
                    w, h = version.get("width", 0), version.get("height", 0)
                    return w * h if isinstance(w, (int, float)) and isinstance(h, (int, float)) else 0
                versions.sort(key=area, reverse=True)
                if versions:
                    return dict(id="reel:" + shortcode, url=versions[0]["url"],
                                fallback=versions[-1]["url"] if len(versions) > 1 else None,
                                headers={"User-Agent": user_agent})
            pending.extend(node.values())
    return None


def headless_reels(source, count, *, resolve=False):
    page = obscura(source, DISCOVER_JS.replace("COUNT", str(count)), 150)
    links = [link for link in page.get("links", []) if isinstance(link, str)][:count]
    if len(links) < 2:
        raise FixtureError("The source did not expose enough playable public clips to the isolated browser. "
                           "It may require login or be limiting access. Try later or use another public source. "
                           "Your passphrase and display permissions do not need changing.")
    if not resolve:
        return links
    clips = []
    for index, link in enumerate(links):
        detail = obscura(link, RESOLVE_JS, 50)
        clip = media_from_documents(detail.get("documents", []), link.strip("/").rsplit("/", 1)[-1],
                                    detail.get("agent", ""))
        if clip:
            clips.append(clip)
        # Only fixed progress messages. This carries private data no further than the parent.
        print(f"Checked clip {index + 1}/{len(links)}", file=sys.stderr, flush=True)
    if len(clips) < 2:
        raise FixtureError("Fewer than two clips exposed a playable public stream.")
    return clips


def prepare_clips(source, count, min_fps=0):
    if urlparse(source).hostname == "www.instagram.com":
        print("Reading public video streams in the isolated browser…", flush=True)
        clips = headless_reels(source, count, resolve=True)
        print(f"Resolved {len(clips)} distinct clips. Checking their actual playback rate next.", flush=True)
        return clips
    return resolve_clips(discover_clips(source, count), min_fps)


def resolver_executable():
    local = Path(sys.executable).parent / "yt-dlp"
    return str(local) if local.is_file() else shutil.which("yt-dlp")


def check_dependencies(source):
    if not resolver_executable():
        raise FixtureError("Required tools are missing. Click Prepare required tools, then retry.")
    if urlparse(source).hostname == "www.instagram.com" and not shutil.which("obscura"):
        raise FixtureError("The isolated browser is missing. Click Prepare required tools, then retry.")


def discover_clips(source, count):
    if urlparse(source).hostname == "www.instagram.com":
        return headless_reels(source, count)
    executable = resolver_executable()
    if not executable:
        raise FixtureError("Install yt-dlp to resolve the source streams.")
    result = run_child([executable, "--ignore-config", "--no-cache-dir", "--no-plugin-dirs",
        "--flat-playlist", "--playlist-end", str(count), "--skip-download", "--no-warnings",
        "--dump-single-json", "--socket-timeout", "15", "--retries", "0", "--batch-file", "-"],
        input=source + "\n", text=True, capture_output=True, timeout=120)
    if result.returncode:
        raise FixtureError("The profile could not be read. No media files were saved.")
    entries = json.loads(result.stdout).get("entries", [])
    prefix = source + "/video/"
    links = list(dict.fromkeys(item.get("url", "") for item in entries
                 if item.get("url", "").startswith(prefix)
                 and item["url"][len(prefix):].isdigit()))
    if len(links) < 2:
        raise FixtureError("Fewer than two distinct videos were available.")
    return links[:count]


def allowed_media_url(value):
    url = urlparse(value)
    host = url.hostname or ""
    return (url.scheme == "https" and not url.username and not url.password
            and url.port in (None, 443)
            and any(host == suffix or host.endswith("." + suffix) for suffix in MEDIA_HOSTS))


def resolve_clips(links, min_fps=0):
    executable = resolver_executable()
    if not executable:
        raise FixtureError("Install yt-dlp to resolve the source streams.")
    clips, seen, failures = [], set(), set()
    links = list(dict.fromkeys(links))
    for index, link in enumerate(links):
        parsed = urlparse(link)
        if (parsed.scheme == "https" and parsed.hostname == "www.tiktok.com"
                and re.fullmatch(r"/@[A-Za-z0-9_.]+/video/[0-9]+", parsed.path)):
            # Resolve and read the stream in the same downloader session. Some CDN
            # URLs reject a second client even though the downloader can read them.
            identity = "TikTok:" + parsed.path.rsplit("/", 1)[1]
            if identity not in seen:
                seen.add(identity)
                clips.append(dict(id=identity, source=link))
                print(f"Queued clip {index + 1}/{len(links)} for memory-only streaming", flush=True)
            continue
        # URLs travel over stdin, not argv. Ignore user config and disable cache/output
        # files, plugins, playlists, sidecars and verbose logs for this read-only call.
        result = run_child([
            executable, "--ignore-config", "--no-plugin-dirs", "--no-cache-dir",
            "--skip-download", "--no-playlist", "--no-warnings", "--dump-single-json",
            "--socket-timeout", "15", "--retries", "0", "-f",
            (f"bestvideo[fps>={min_fps - 0.1}]/best[fps>={min_fps - 0.1}]/bestvideo/best"
             if min_fps else "bestvideo/best"),
            "--batch-file", "-"], input=link + "\n", text=True,
            capture_output=True, timeout=60)
        if result.returncode:
            error = result.stderr.lower()
            reason = ("access limited or login required" if any(word in error for word in
                      ("login", "log in", "rate-limit", "rate limit", "429", "403")) else
                      "connection timed out" if "timed out" in error else "stream unavailable")
            failures.add(reason)
            print(f"Skipped clip {index + 1}/{len(links)}: {reason}", flush=True)
            continue
        data = json.loads(result.stdout)
        url = data.get("url", "")
        if not allowed_media_url(url):
            raise FixtureError("The resolver did not return an allowed direct video stream.")
        identity = f"{data.get('extractor_key', data.get('extractor', ''))}:{data.get('id', '')}"
        if not data.get("id") or identity in seen:
            continue
        seen.add(identity)
        # Keep a progressive source for streams with unreadable container metadata.
        # A fallback's actual resolution/rate is always reported by the player.
        progressive = next((f for f in reversed(data.get("formats", []))
                            if f.get("vcodec") != "none" and f.get("acodec") != "none"
                            and f.get("protocol") == "https"
                            and allowed_media_url(f.get("url", ""))), None)
        headers = {k: v for k, v in data.get("http_headers", {}).items()
                   if k.lower() in ("user-agent", "referer") and isinstance(v, str)}
        clips.append(dict(id=identity, url=url, headers=headers,
                          fallback=progressive.get("url") if progressive else None))
        print(f"Resolved clip {index + 1}/{len(links)}", flush=True)
        if index + 1 < len(links):
            time.sleep(1)
    if len(clips) < 2:
        if "access limited or login required" in failures:
            raise FixtureError("The source is limiting anonymous video access or requires login. "
                               "Try later or use another public source. Your passphrase and display permissions do not need changing.")
        raise FixtureError("Fewer than two distinct videos could be resolved.")
    return clips


def play(binary, clips, seconds, full, fraction, check=False, videos_per_screen=0, min_fps=0):
    request = dict(mode="play", clips=clips, seconds=seconds, full=full,
                   fraction=fraction, check=check, videosPerScreen=videos_per_screen, minFPS=min_fps,
                   resolver=resolver_executable())
    return run_child([str(binary)], input=json.dumps(request).encode(),
                     timeout=seconds + min(900, len(clips) * 60 + 30)).returncode


def run_fixture(binary, source, count, seconds, full, fraction, check=False, videos_per_screen=0, min_fps=0):
    try:
        with RunWorkspace():
            print("Temporary storage checked. This run uses a disposable folder.", flush=True)
            check_dependencies(source)
            clips = prepare_clips(source, count, min_fps)
            print("Checking playback…" if check else "Preparing playback. Press Escape to stop.", flush=True)
            return play(binary, clips, seconds, full, fraction, check, videos_per_screen, min_fps)
    except CleanupError as error:
        raise FixtureError(str(error)) from None


def per_screen(value):
    if value == "auto":
        return 0
    try:
        number = int(value)
        if 1 <= number <= MAX_CLIPS:
            return number
    except ValueError:
        pass
    raise argparse.ArgumentTypeError("use auto or a number from 1 to 96")


def main(argv=None):
    parser = argparse.ArgumentParser(description="Local fixture runner; never bundled with Oizys.")
    parser.add_argument("action", choices=("init", "source", "run", "check"))
    parser.add_argument("--full", action="store_true")
    parser.add_argument("--seconds", type=float, default=120)
    parser.add_argument("--fraction", type=float, default=0.6)
    parser.add_argument("--count", type=int, default=None, help="candidate pool, default 24; maximum 96")
    parser.add_argument("--videos-per-screen", type=per_screen, default=0, metavar="N|auto",
                        help="per-screen limit; auto distributes all eligible unique clips")
    parser.add_argument("--unique-across-screens", action="store_true", default=True,
                        help="explicitly request the default: never reuse a clip on any screen")
    parser.add_argument("--min-fps", type=float, default=0,
                        help="skip slower sources; 60 accepts 59.94 fps, without interpolation")
    args = parser.parse_args(argv)
    if (not math.isfinite(args.seconds) or not 1 <= args.seconds <= 3600
            or not math.isfinite(args.fraction) or not 0.1 <= args.fraction <= 1
            or (args.count is not None and not 2 <= args.count <= MAX_CLIPS)
            or not math.isfinite(args.min_fps) or not 0 <= args.min_fps <= 240):
        parser.error("seconds: 1..3600, fraction: 0.1..1, count: 2..96, min-fps: 0..240")
    try:
        if sys.platform != "darwin":
            raise FixtureError("This local fixture requires macOS.")
        if os.environ.get("CONFIGURATION", "").lower().startswith(("production", "release")):
            raise FixtureError("Fixtures are disabled in production/release build environments.")
        resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
        if not sys.stdin.isatty():
            raise FixtureError("Use an interactive terminal; keys cannot be supplied in argv or env.")
        if args.action == "init" and SETTINGS.exists():
            raise FixtureError("Fixture settings already exist; initialization will not overwrite them.")
        if args.action != "init" and not SETTINGS.exists():
            raise FixtureError("Run --fixture init in a terminal first.")
        binary = build_player()
        if args.action == "init":
            source = validate_source(getpass.getpass("Source profile URL (hidden): "))
            phrase = getpass.getpass("New fixture passphrase (at least 16 characters): ")
            if len(phrase) < 16 or phrase != getpass.getpass("Repeat passphrase: "):
                raise FixtureInputError("Passphrases must match and contain at least 16 characters.")
            seal_settings(binary, SETTINGS, source, phrase)
            print("Encrypted source saved locally. The passphrase is not stored.")
            return 0
        phrase = getpass.getpass("Fixture passphrase: ")
        source = open_settings(binary, SETTINGS, phrase)
        if args.action == "source":
            source = validate_source(getpass.getpass("New source profile URL (hidden): "))
            seal_settings(binary, SETTINGS, source, phrase, replace=True)
            print("Encrypted source updated. Passphrase unchanged.")
            return 0
        del phrase
        screens = json.loads(invoke(binary, dict(mode="screens")))
        count = args.count or min(MAX_CLIPS, max(24, len(screens) * args.videos_per_screen))
        return run_fixture(binary, source, count, args.seconds, args.full, args.fraction,
                           args.action == "check", args.videos_per_screen, args.min_fps)
    except (OSError, ValueError, KeyError, RuntimeError, subprocess.SubprocessError) as error:
        # Child errors/JSON can contain signed URLs. Only our own errors are printable.
        print(str(error) if isinstance(error, FixtureError)
              else "Fixture operation failed; no media files were saved.", file=sys.stderr)
        return 1
    except (KeyboardInterrupt, EOFError):
        return 130


if __name__ == "__main__":
    sys.exit(main())
