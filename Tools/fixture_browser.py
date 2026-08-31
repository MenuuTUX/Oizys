"""Read public clip metadata in an isolated, temporary Firefox instance."""
import json
import re
import signal
import sys
from urllib.parse import urlparse


class BrowserAccessError(RuntimeError):
    pass


def media_from_documents(documents, shortcode, user_agent):
    """Use only metadata attached to this clip, never recommendations or page text."""
    from fixture import allowed_media_url

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


def check_page_access(page):
    current = urlparse(page.url)
    if (current.hostname not in ("www.instagram.com", "instagram.com")
            or current.path.startswith(("/accounts/", "/challenge/", "/checkpoint/"))):
        raise BrowserAccessError()


def resolve_page(page, link, user_agent):
    from playwright.sync_api import TimeoutError as BrowserTimeout

    shortcode = urlparse(link).path.strip("/").split("/")[-1]
    try:
        response = page.goto(link, wait_until="domcontentloaded", timeout=45000)
        if response and response.status in (401, 403, 429):
            raise BrowserAccessError()
        for _ in range(8):
            check_page_access(page)
            documents = []
            for script in page.locator('script[type="application/json"]').all_text_contents():
                try:
                    documents.append(json.loads(script))
                except ValueError:
                    pass
            clip = media_from_documents(documents, shortcode, user_agent)
            if clip:
                return clip
            page.wait_for_timeout(500)
    except BrowserTimeout:
        return None
    return None


def stop(*_):
    raise KeyboardInterrupt


def main():
    from playwright.sync_api import sync_playwright
    from fixture import validate_source

    request = json.loads(sys.stdin.read(65536))
    source, count = validate_source(request["source"]), int(request["count"])
    if urlparse(source).hostname != "www.instagram.com" or not 2 <= count <= 96:
        return 2
    signal.signal(signal.SIGINT, stop)
    signal.signal(signal.SIGTERM, stop)
    with sync_playwright() as runtime:
        browser = runtime.firefox.launch(headless=True, firefox_user_prefs={
            "browser.cache.disk.enable": False, "browser.cache.offline.enable": False,
            "media.autoplay.default": 5,
        })
        try:
            context = browser.new_context(accept_downloads=False, service_workers="block",
                                          viewport={"width": 1280, "height": 900})
            context.route("**/*", lambda route: route.abort() if route.request.resource_type == "media" else route.continue_())
            page = context.new_page()
            response = page.goto(source, wait_until="domcontentloaded", timeout=45000)
            if response and response.status in (401, 403, 429):
                raise BrowserAccessError()
            collected, stale = [], 0
            for _ in range(48):
                check_page_access(page)
                before = len(collected)
                links = page.locator("a[href]").evaluate_all("nodes => nodes.map(a => a.href)")
                for value in links:
                    url = urlparse(value)
                    if url.scheme == "https" and url.hostname in ("www.instagram.com", "instagram.com"):
                        match = re.fullmatch(r"/(?:[A-Za-z0-9_.]+/)?reel/([A-Za-z0-9_-]+)/?", url.path)
                        if match:
                            canonical = "https://www.instagram.com/reel/" + match[1] + "/"
                            if canonical not in collected:
                                collected.append(canonical)
                stale = stale + 1 if before == len(collected) else 0
                if len(collected) >= count or stale >= 8:
                    break
                page.evaluate("window.scrollTo(0, document.body.scrollHeight)")
                page.wait_for_timeout(1000)
            if len(collected) < 2:
                raise BrowserAccessError()
            if request.get("resolve") is True:
                user_agent = page.evaluate("navigator.userAgent")
                clips = []
                for index, link in enumerate(collected[:count]):
                    clip = resolve_page(page, link, user_agent)
                    if clip:
                        clips.append(clip)
                    # Only fixed progress messages. stdout carries private data to the parent.
                    print(f"Checked clip {index + 1}/{min(count, len(collected))}", file=sys.stderr, flush=True)
                if len(clips) < 2:
                    raise BrowserAccessError()
                print(json.dumps(clips))
            else:
                print(json.dumps(collected[:count]))
        finally:
            browser.close()
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        sys.exit(130)
    except BrowserAccessError:
        sys.exit(3)
    except Exception:
        # Browser errors can contain private profile URLs. Never forward them.
        print("Isolated discovery unavailable; no personal browser was accessed.", file=sys.stderr)
        sys.exit(1)
