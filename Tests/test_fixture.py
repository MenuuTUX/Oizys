"""Authentication and release boundaries. Never open displays or contact Instagram."""
import base64
import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import os
import signal
import time

import pytest

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "Tools"))
spec = importlib.util.spec_from_file_location("local_fixture", ROOT / "Tools/fixture.py")
fixture = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fixture)

SOURCE = "https://www.instagram.com/fixture_account/reels/"
PHRASE = "only a disposable test passphrase"


@pytest.fixture(scope="module")
def player():
    if sys.platform != "darwin":
        pytest.skip("CryptoKit helper requires macOS")
    return fixture.build_player()


def test_encrypted_source_roundtrip_and_permissions(player, tmp_path):
    first, second = tmp_path / "a.json", tmp_path / "b.json"
    fixture.seal_settings(player, first, SOURCE, PHRASE)
    fixture.seal_settings(player, second, SOURCE, PHRASE)
    assert fixture.open_settings(player, first, PHRASE) == SOURCE
    assert first.read_bytes() != second.read_bytes()
    assert SOURCE.encode() not in first.read_bytes()
    assert PHRASE.encode() not in first.read_bytes()
    assert first.stat().st_mode & 0o777 == 0o600
    assert set(tmp_path.iterdir()) == {first, second}


def test_wrong_key_and_tampering_fail_closed(player, tmp_path):
    path = tmp_path / "settings.json"
    fixture.seal_settings(player, path, SOURCE, PHRASE)
    with pytest.raises(RuntimeError):
        fixture.open_settings(player, path, "wrong passphrase")
    original = json.loads(path.read_text())
    for field in ("sealed", "salt"):
        value = dict(original)
        damaged = bytearray(base64.b64decode(value[field]))
        damaged[-1] ^= 1
        value[field] = base64.b64encode(damaged).decode()
        path.write_text(json.dumps(value))
        with pytest.raises(RuntimeError):
            fixture.open_settings(player, path, PHRASE)


def test_init_cannot_overwrite_existing_settings(player, tmp_path):
    path = tmp_path / "settings.json"
    fixture.seal_settings(player, path, SOURCE, PHRASE)
    before = path.read_bytes()
    with pytest.raises(FileExistsError):
        fixture.seal_settings(player, path, SOURCE, "a different disposable passphrase")
    assert path.read_bytes() == before


def test_unlock_helper_check_needs_no_saved_settings(player):
    fixture.check_crypto(player)


def test_settings_from_previous_release_remain_readable(player):
    # Produced by the previous release, rather than encrypted by the current helper.
    ciphertext = "afG4SDwS10VbDb1/phMyxHRlv/y1cuo5ANPulnJLFE05OSZLiJ8fAAOsai0eTuy1lJglNp2SxmsmvqU1lOu9b6hUdPtL"
    plain = fixture.invoke(player, dict(mode="open", key=base64.b64encode(bytes(range(32))).decode(), data=ciphertext))
    assert plain == b"existing encrypted settings stay readable"


def test_start_over_preserves_old_ciphertext_and_uses_new_passphrase(player, tmp_path):
    path = tmp_path / "settings.json"
    fixture.seal_settings(player, path, SOURCE, PHRASE)
    original = path.read_bytes()
    new_phrase = "four entirely different private words"
    backup = fixture.replace_settings(player, path, SOURCE, new_phrase)
    assert backup.read_bytes() == original
    assert fixture.open_settings(player, backup, PHRASE) == SOURCE
    assert fixture.open_settings(player, path, new_phrase) == SOURCE
    with pytest.raises(fixture.FixtureUnlockError):
        fixture.open_settings(player, path, PHRASE)
    assert backup.stat().st_mode & 0o777 == 0o600
    assert path.stat().st_mode & 0o777 == 0o600
    assert SOURCE.encode() not in path.read_bytes()
    assert new_phrase.encode() not in path.read_bytes()


def test_start_over_invalid_input_does_not_change_saved_settings(player, tmp_path):
    path = tmp_path / "settings.json"
    fixture.seal_settings(player, path, SOURCE, PHRASE)
    original = path.read_bytes()
    with pytest.raises(fixture.FixtureInputError):
        fixture.replace_settings(player, path, "invalid-source", PHRASE)
    assert path.read_bytes() == original
    assert set(tmp_path.iterdir()) == {path}


def test_start_over_preserves_original_if_atomic_replacement_fails(player, tmp_path, monkeypatch):
    path = tmp_path / "settings.json"
    fixture.seal_settings(player, path, SOURCE, PHRASE)
    original = path.read_bytes()
    def fail(*args):
        raise OSError("simulated disk failure")
    monkeypatch.setattr(fixture.os, "replace", fail)
    with pytest.raises(OSError):
        fixture.replace_settings(player, path, SOURCE, PHRASE)
    assert path.read_bytes() == original
    backups = list(tmp_path.glob("fixture-backup-*.json"))
    assert len(backups) == 1 and backups[0].read_bytes() == original


@pytest.mark.parametrize("status,expected", [(3, fixture.FixtureUnlockError), (1, fixture.FixtureError), (-9, fixture.FixtureError)])
def test_unlock_error_is_not_used_for_helper_crashes(monkeypatch, status, expected):
    monkeypatch.setattr(fixture, "run_child", lambda *a, **kw: subprocess.CompletedProcess(a[0], status, b"", b"private error"))
    with pytest.raises(expected) as error:
        fixture.invoke("/unused/helper", dict(mode="open"))
    assert type(error.value) is expected
    assert "private error" not in str(error.value)


@pytest.mark.parametrize("url", [
    "http://www.instagram.com/test/reels/", "https://instagram.com.evil.invalid/test/reels/",
    "https://user:secret@instagram.com/test/reels/", "file:///tmp/movie.mp4",
    "https://instagram.com/test/reels/?token=value", "https://instagram.com/test/post/",
])
def test_source_rejects_unrelated_hosts_or_credential_urls(url):
    with pytest.raises(ValueError):
        fixture.validate_source(url)


@pytest.mark.parametrize("value", ["https://instagram.com/fixture_account", "  https://www.instagram.com/fixture_account/  ", SOURCE])
def test_profile_url_is_normalized_without_requiring_reels_suffix(value):
    assert fixture.validate_source(value) == SOURCE


def test_missing_tools_report_a_safe_action(monkeypatch):
    monkeypatch.setattr(fixture, "resolver_executable", lambda: None)
    with pytest.raises(fixture.FixtureError, match="Prepare required tools") as error:
        fixture.check_dependencies(SOURCE)
    assert SOURCE not in str(error.value)


@pytest.mark.parametrize("safe", [True, False])
def test_private_runner_only_prints_explicitly_safe_errors(safe):
    code = (
        f"import sys; sys.path.insert(0, {str(ROOT / 'Tools')!r}); import dev_runner\n"
        "def fail(request):\n"
        + (" raise dev_runner.fixture.FixtureError('Required tools are missing. Click Prepare required tools.')\n"
           if safe else " raise RuntimeError(request['source'] + request['passphrase'])\n")
        + "dev_runner.private_request = fail\nsys.exit(dev_runner.main())\n"
    )
    result = subprocess.run([sys.executable, "-c", code],
                            input=json.dumps(dict(tool="fixture", source=SOURCE, passphrase=PHRASE)),
                            capture_output=True, text=True, timeout=10)
    assert result.returncode == 1
    output = result.stdout + result.stderr
    assert "Prepare required tools" in output
    assert SOURCE not in output and PHRASE not in output


@pytest.mark.parametrize("configuration", ["Production", "ProductionFallback", "Release"])
def test_release_environment_rejects_before_prompt_or_build(monkeypatch, configuration):
    monkeypatch.setenv("CONFIGURATION", configuration)
    monkeypatch.setattr(fixture, "build_player", lambda: pytest.fail("unexpected build"))
    monkeypatch.setattr(fixture.getpass, "getpass", lambda _: pytest.fail("unexpected prompt"))
    assert fixture.main(["run"]) == 1


def test_helper_cannot_compile_for_release(player):
    for flags in ([], ["-D", "OIZYS_FIXTURE_DEBUG", "-D", "OIZYS_PRODUCTION"]):
        result = subprocess.run(["xcrun", "swiftc", "-typecheck", *flags,
            "-module-cache-path", str(ROOT / "build/ModuleCache"), str(fixture.SOURCE)],
            capture_output=True, text=True)
        assert result.returncode != 0
        assert "must not be built into Oizys products" in result.stderr


@pytest.mark.parametrize("script", ["test.py", "profile.py"])
def test_fixture_dispatch_does_not_load_driver_or_advertise_in_normal_help(script):
    env = dict(os.environ, OIZYS_DYLIB="/nonexistent/library.dylib")
    result = subprocess.run([sys.executable, str(ROOT / "Tools" / script),
                             "--fixture", "--help"], env=env, capture_output=True, text=True)
    assert result.returncode == 0
    assert "--full" in result.stdout
    # profile.py normally imports the driver before parsing, so omit the poison path here.
    result = subprocess.run([sys.executable, str(ROOT / "Tools" / script), "--help"],
                            capture_output=True, text=True)
    assert result.returncode == 0
    assert "--fixture" not in result.stdout


def test_ctrl_c_stops_resolver_and_its_grandchildren(tmp_path):
    marker = tmp_path / "children.json"
    child = (
        "import os,signal,subprocess,sys,time,json; "
        "signal.signal(signal.SIGTERM,signal.SIG_IGN); "
        "p=subprocess.Popen([sys.executable,'-c','import time; time.sleep(60)']); "
        f"open({str(marker)!r},'w').write(json.dumps([os.getpid(),p.pid])); "
        "time.sleep(60)"
    )
    runner_code = (
        f"import sys; sys.path.insert(0,{str(ROOT / 'Tools')!r}); import fixture\n"
        "try:\n"
        f" fixture.run_child([sys.executable,'-c',{child!r}])\n"
        "except KeyboardInterrupt:\n"
        " sys.exit(130)\n"
    )
    runner = subprocess.Popen([sys.executable, "-c", runner_code],
                               stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    children = []
    try:
        deadline = time.monotonic() + 5
        while not marker.exists() and time.monotonic() < deadline:
            time.sleep(0.02)
        assert marker.exists(), "child process did not start"
        children = json.loads(marker.read_text())
        started = time.monotonic()
        runner.send_signal(signal.SIGINT)
        runner.communicate(timeout=4)
        assert runner.returncode == 130
        assert time.monotonic() - started < 3
        # A killed orphan may briefly remain a zombie until launchd/init reaps it.
        for pid in children:
            status = subprocess.run(["ps", "-o", "stat=", "-p", str(pid)],
                                    capture_output=True, text=True).stdout.strip()
            assert not status or status.startswith("Z"), f"child {pid} survived: {status}"
    finally:
        for pid in children:
            try:
                os.kill(pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
        if runner.poll() is None:
            runner.kill()
        runner.wait()


def test_tiktok_source_can_replace_encrypted_setting(player, tmp_path):
    path = tmp_path / "source.json"
    fixture.seal_settings(player, path, SOURCE, PHRASE)
    new_source = "https://www.tiktok.com/@fixture_account"
    assert fixture.validate_source("https://tiktok.com/@fixture_account/") == new_source
    fixture.seal_settings(player, path, new_source, PHRASE, replace=True)
    assert fixture.open_settings(player, path, PHRASE) == new_source
    assert new_source.encode() not in path.read_bytes()
    assert path.stat().st_mode & 0o777 == 0o600
    assert set(tmp_path.iterdir()) == {path}


@pytest.mark.parametrize("url,allowed", [
    ("https://v16-webapp-prime.tiktok.com/video", True),
    ("https://v16m.tiktokcdn.com/video", True),
    ("https://scontent.cdninstagram.com/video", True),
    ("https://tiktok.com.evil.invalid/video", False),
    ("http://v16-webapp-prime.tiktok.com/video", False),
    ("https://user:secret@v16-webapp-prime.tiktok.com/video", False),
    ("https://v16-webapp-prime.tiktok.com:8080/video", False),
])
def test_media_urls_remain_restricted(url, allowed):
    assert fixture.allowed_media_url(url) is allowed


def test_resolver_deduplicates_source_ids_and_keeps_only_safe_headers(monkeypatch):
    responses = iter([
        dict(id="one", extractor_key="TikTok", url="https://v16m.tiktokcdn.com/a",
             http_headers={"User-Agent": "test", "Cookie": "never-forward"}),
        dict(id="one", extractor_key="TikTok", url="https://v16m.tiktokcdn.com/a?new-signature"),
        dict(id="two", extractor_key="TikTok", url="https://v16m.tiktokcdn.com/b"),
    ])
    monkeypatch.setattr(fixture, "resolver_executable", lambda: "/mock/yt-dlp")
    monkeypatch.setattr(fixture.time, "sleep", lambda _: None)
    monkeypatch.setattr(fixture, "run_child", lambda *a, **kw: subprocess.CompletedProcess(
        a[0], 0, json.dumps(next(responses)), ""))
    clips = fixture.resolve_clips(["a", "a", "alias-of-a", "b"])
    assert [clip["id"] for clip in clips] == ["TikTok:one", "TikTok:two"]
    assert clips[0]["headers"] == {"User-Agent": "test"}


def test_browser_metadata_uses_only_requested_clip_and_allowed_streams(monkeypatch):
    from fixture import media_from_documents

    documents = [{"nested": [
        {"code": "recommendation", "video_versions": [{"url": "https://scontent.cdninstagram.com/unrelated"}]},
        {"code": "requested", "video_versions": [
            {"url": "https://scontent.cdninstagram.com/small", "width": 320, "height": 480},
            {"url": "https://scontent.cdninstagram.com/large", "width": 720, "height": 1280},
            {"url": "https://untrusted.invalid/media", "width": 4000, "height": 8000},
            {"url": "https://user:secret@scontent.cdninstagram.com/private"},
        ]},
    ]}]
    clip = media_from_documents(documents, "requested", "test-agent")
    assert clip == dict(id="reel:requested", url="https://scontent.cdninstagram.com/large",
                        fallback="https://scontent.cdninstagram.com/small", headers={"User-Agent": "test-agent"})
    assert media_from_documents(documents, "absent", "test-agent") is None


def test_browser_metadata_accepts_missing_dimensions_and_rejects_unbound_video(monkeypatch):
    from fixture import media_from_documents

    url = "https://scontent.cdninstagram.com/video"
    assert media_from_documents([{"video_versions": [{"url": url}]}], "requested", "test") is None
    clip = media_from_documents([{"code": "requested", "video_versions": [{"url": url}]}], "requested", "test")
    assert clip["url"] == url and clip["fallback"] is None


def test_public_browser_source_does_not_return_to_downloader(monkeypatch):
    calls = []
    expected = [{"id": "one"}, {"id": "two"}]
    def browser(source, count, *, resolve=False):
        calls.append((source, count, resolve))
        return expected
    monkeypatch.setattr(fixture, "headless_reels", browser)
    monkeypatch.setattr(fixture, "resolve_clips", lambda *a: pytest.fail("unexpected downloader handoff"))
    assert fixture.prepare_clips(SOURCE, 6, 60) == expected
    assert calls == [(SOURCE, 6, True)]


def obscura_reply(payload, status=0):
    """What `obscura scrape --format json` writes on stdout, with the page's own JSON in eval."""
    body = json.dumps({"results": [{"url": SOURCE, "eval": json.dumps(payload)}]})
    return lambda *a, **kw: subprocess.CompletedProcess(a[0], status, body, SOURCE + PHRASE)


def test_browser_transport_failure_is_redacted(monkeypatch):
    # A non-zero exit is the browser not completing: connection, missing binary, timeout.
    # Its stderr can carry the source URL, so none of it may reach the message.
    monkeypatch.setattr(fixture, "run_child", lambda *a, **kw: subprocess.CompletedProcess(
        a[0], 1, SOURCE, SOURCE + PHRASE))
    with pytest.raises(fixture.FixtureError) as error:
        fixture.headless_reels(SOURCE, 6, resolve=True)
    assert SOURCE not in str(error.value) and PHRASE not in str(error.value)
    assert "connection" in str(error.value)


@pytest.mark.parametrize("landing", ["/accounts/login/", "/challenge/", "/checkpoint/x"])
def test_browser_login_wall_is_named_as_access_not_failure(monkeypatch, landing):
    # obscura exits 0 whatever the page turned out to be, so a login wall has to be read off
    # the page it actually landed on. Getting this wrong would report a private profile as a
    # broken connection and send the user to fix their network.
    monkeypatch.setattr(fixture, "run_child", obscura_reply(
        {"host": "www.instagram.com", "path": landing, "agent": "t", "links": []}))
    with pytest.raises(fixture.FixtureError) as error:
        fixture.headless_reels(SOURCE, 6, resolve=True)
    assert SOURCE not in str(error.value) and PHRASE not in str(error.value)
    assert "login" in str(error.value) and "permissions do not need changing" in str(error.value)


def test_browser_redirected_off_the_host_is_treated_as_no_access(monkeypatch):
    monkeypatch.setattr(fixture, "run_child", obscura_reply(
        {"host": "elsewhere.invalid", "path": "/", "agent": "t", "links": []}))
    with pytest.raises(fixture.FixtureError) as error:
        fixture.headless_reels(SOURCE, 6, resolve=True)
    assert "login" in str(error.value)


def test_browser_unreadable_output_does_not_leak_it(monkeypatch):
    monkeypatch.setattr(fixture, "run_child", lambda *a, **kw: subprocess.CompletedProcess(
        a[0], 0, "not json " + SOURCE, SOURCE + PHRASE))
    with pytest.raises(fixture.FixtureError) as error:
        fixture.headless_reels(SOURCE, 6, resolve=True)
    assert SOURCE not in str(error.value) and PHRASE not in str(error.value)


def test_browser_returns_only_canonical_reel_links(monkeypatch):
    links = ["https://www.instagram.com/reel/AAA/", "https://www.instagram.com/reel/BBB/"]
    monkeypatch.setattr(fixture, "run_child", obscura_reply(
        {"host": "www.instagram.com", "path": "/someone/reels/", "agent": "t", "links": links}))
    assert fixture.headless_reels(SOURCE, 6) == links


def test_browser_refuses_a_source_exposing_fewer_than_two_clips(monkeypatch):
    monkeypatch.setattr(fixture, "run_child", obscura_reply(
        {"host": "www.instagram.com", "path": "/someone/reels/", "agent": "t",
         "links": ["https://www.instagram.com/reel/AAA/"]}))
    with pytest.raises(fixture.FixtureError):
        fixture.headless_reels(SOURCE, 6)


def test_downloader_access_error_is_actionable_without_raw_stderr(monkeypatch, capsys):
    monkeypatch.setattr(fixture, "resolver_executable", lambda: "/mock/resolver")
    monkeypatch.setattr(fixture, "run_child", lambda *a, **kw: subprocess.CompletedProcess(
        a[0], 1, "null", "login required: " + SOURCE + PHRASE))
    with pytest.raises(fixture.FixtureError, match="limiting anonymous video access") as error:
        fixture.resolve_clips(["one", "two"])
    output = capsys.readouterr().out + str(error.value)
    assert "access limited or login required" in output
    assert SOURCE not in output and PHRASE not in output


def layout(player, count, screens, limit=0, sizes=None):
    request = dict(mode="layout", videosPerScreen=limit,
        layoutSizes=sizes or [dict(width=1080, height=1920)] * count,
        screenSizes=[dict(width=w, height=h) for w, h in screens])
    return json.loads(fixture.invoke(player, request))


@pytest.mark.parametrize("count,screen_count,limit", [
    (2, 4, 0), (6, 4, 0), (24, 4, 0), (96, 4, 0), (24, 4, 3), (7, 2, 2), (0, 4, 0),
])
def test_layout_never_wraps_or_repeats_a_clip(player, count, screen_count, limit):
    plans = layout(player, count, [(1920, 1080)] * screen_count, limit)
    assigned = [index for plan in plans for index in plan["indices"]]
    expected = min(count, screen_count * limit) if limit else count
    assert len(assigned) == len(set(assigned)) == expected
    assert set(assigned) == set(range(expected))
    counts = [len(plan["indices"]) for plan in plans]
    assert max(counts) - min(counts) <= 1
    if limit:
        assert max(counts) <= limit
    for plan in plans:
        assert plan["rows"] * plan["columns"] >= len(plan["indices"])


def test_dense_portrait_grid_uses_multiple_rows(player):
    plans = layout(player, 48, [(1920, 1080)] * 4)
    assert all(len(plan["indices"]) == 12 for plan in plans)
    assert all(plan["rows"] == 2 and plan["columns"] == 6 for plan in plans)


def test_mixed_aspect_ratios_fit_without_crop_or_distortion(player):
    sizes = [dict(width=w, height=h) for w, h in
             [(1080, 1920), (1920, 1080), (1080, 1080), (4096, 2160), (720, 1280)]]
    screens = [(1920, 1080), (1080, 1920)]
    plans = layout(player, len(sizes), screens, sizes=sizes)
    for (width, height), plan in zip(screens, plans):
        cell_w, cell_h = width / plan["columns"], height / plan["rows"]
        for index in plan["indices"]:
            source = sizes[index]
            scale = min(cell_w / source["width"], cell_h / source["height"])
            w, h = source["width"] * scale, source["height"] * scale
            assert 0 < w <= cell_w + 1e-6 and 0 < h <= cell_h + 1e-6
            assert w / h == pytest.approx(source["width"] / source["height"])


def test_video_count_argument_supports_auto_and_dense_runs():
    assert fixture.per_screen("auto") == 0
    assert fixture.per_screen("24") == 24
    with pytest.raises(Exception, match="use auto or a number"):
        fixture.per_screen("0")
