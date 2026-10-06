import time

import pytest

from app.services.scan_enrich import enrich, is_bot

IPHONE = (
    "Mozilla/5.0 (iPhone; CPU iPhone OS 17_4 like Mac OS X) AppleWebKit/605.1.15 "
    "(KHTML, like Gecko) Version/17.4 Mobile/15E148 Safari/604.1"
)
ANDROID = (
    "Mozilla/5.0 (Linux; Android 14; Pixel 8) AppleWebKit/537.36 (KHTML, like Gecko) "
    "Chrome/124.0.6367.82 Mobile Safari/537.36"
)
ANDROID_TABLET = (
    "Mozilla/5.0 (Linux; Android 13; SM-X700) AppleWebKit/537.36 (KHTML, like Gecko) "
    "Chrome/124.0.0.0 Safari/537.36"
)
IPAD = (
    "Mozilla/5.0 (iPad; CPU OS 17_4 like Mac OS X) AppleWebKit/605.1.15 "
    "(KHTML, like Gecko) Version/17.4 Mobile/15E148 Safari/604.1"
)
WIN_EDGE = (
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) "
    "Chrome/124.0.0.0 Safari/537.36 Edg/124.0.2478.67"
)
MAC_FIREFOX = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10.15; rv:125.0) Gecko/20100101 Firefox/125.0"
LINUX_CHROME = (
    "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) "
    "Chrome/124.0.0.0 Safari/537.36"
)

BOTS = [
    "Mozilla/5.0 (compatible; Googlebot/2.1; +http://www.google.com/bot.html)",
    "Mozilla/5.0 (compatible; bingbot/2.0; +http://www.bing.com/bingbot.htm)",
    "facebookexternalhit/1.1 (+http://www.facebook.com/externalhit_uatext.php)",
    "Twitterbot/1.0",
    "Slackbot-LinkExpanding 1.0 (+https://api.slack.com/robots)",
    "WhatsApp/2.23.20.0 A",
    "TelegramBot (like TwitterBot)",
    "curl/8.4.0",
    "Wget/1.21.4",
    "python-requests/2.31.0",
    "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) "
    "HeadlessChrome/124.0.0.0 Safari/537.36",
    "Mozilla/5.0 (compatible; UptimeRobot/2.0; http://www.uptimerobot.com/)",
    "Pingdom.com_bot_version_1.4_(http://www.pingdom.com/)",
    "",
    "   ",
]


@pytest.mark.parametrize(
    ("ua", "device", "os_", "browser"),
    [
        (IPHONE, "mobile", "iOS", "Safari"),
        (ANDROID, "mobile", "Android", "Chrome"),
        (ANDROID_TABLET, "tablet", "Android", "Chrome"),
        (IPAD, "tablet", "iOS", "Safari"),
        (WIN_EDGE, "desktop", "Windows", "Edge"),
        (MAC_FIREFOX, "desktop", "macOS", "Firefox"),
        (LINUX_CHROME, "desktop", "Linux", "Chrome"),
    ],
)
def test_enrich_humans(ua: str, device: str, os_: str, browser: str) -> None:
    e = enrich(ua)
    assert (e.device, e.os, e.browser, e.is_bot) == (device, os_, browser, False)


@pytest.mark.parametrize("ua", BOTS)
def test_enrich_bots(ua: str) -> None:
    e = enrich(ua)
    assert e.is_bot is True and e.device == "bot"
    assert is_bot(ua)


def test_none_ua_is_bot() -> None:
    assert enrich(None).is_bot is True
    assert is_bot(None)


def test_unknown_ua_is_other_and_trimmed() -> None:
    e = enrich("Mozilla/5.0 (X-Weird) Gadget/1")
    assert e.is_bot is False
    assert e.device == "other"
    for v in (e.os, e.browser):
        assert v is None or len(v) <= 64


def test_huge_ua_does_not_blow_up() -> None:
    e = enrich("Mozilla/5.0 " + "A" * 100_000)
    assert e.device is not None


def test_cached_parsing_under_1ms() -> None:
    uas = [IPHONE, ANDROID, IPAD, WIN_EDGE, MAC_FIREFOX, *BOTS]
    for ua in uas:
        enrich(ua)  # calienta la caché
    n = 20_000
    t0 = time.perf_counter()
    for i in range(n):
        enrich(uas[i % len(uas)])
    per_call_ms = (time.perf_counter() - t0) / n * 1000
    print(f"enrich cacheado: {per_call_ms:.5f} ms/UA")
    assert per_call_ms < 1
