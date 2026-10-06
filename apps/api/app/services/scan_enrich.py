"""Enriquecimiento del User-Agent del escaneo (DQR-T040).

- Parsing con `ua-parser` 1.x (regexes uap-core empaquetadas en `ua-parser-builtins`):
  mantenido, sin llamadas de red, sin estado externo.
- `enrich()` está cacheada con LRU: los UA se repiten mucho.
- La lista de bots vive en `BOT_MARKERS` (subcadenas en minúsculas); añade ahí.
"""

from dataclasses import dataclass
from functools import lru_cache

from ua_parser import parse

MAX_LEN = 64  # coincide con el saneado de record_scan (device/os/browser ≤ 64)
_CACHE_SIZE = 4096
_MAX_UA = 1024  # UAs absurdamente largos no se parsean enteros

BOT_MARKERS: tuple[str, ...] = (
    # genéricos
    "bot", "spider", "crawl", "slurp", "scraper", "fetch", "monitor", "preview",
    "headless", "phantomjs", "lighthouse",
    # buscadores y redes (Googlebot, bingbot, Twitterbot, Slackbot, ...) ya caen en "bot"
    "facebookexternalhit", "facebot", "whatsapp", "telegram", "skypeuripreview",
    "discordbot", "linkedinbot", "embedly", "quora link preview", "pinterest",
    "yandex", "baiduspider", "duckduckgo", "applebot", "google-inspectiontool",
    # clientes HTTP / CLIs
    "curl/", "wget", "python-requests", "python-urllib", "aiohttp", "httpx",
    "go-http-client", "okhttp", "java/", "libwww", "node-fetch", "axios", "postmanruntime",
    # uptime monitors
    "uptimerobot", "pingdom", "statuscake", "site24x7", "newrelic", "datadog", "zabbix",
    "nagios", "better uptime", "betterstack", "healthcheck", "gtmetrix",
)  # fmt: skip

_DESKTOP_OS = {"windows", "mac os x", "macos", "linux", "ubuntu", "fedora", "debian", "chrome os"}


@dataclass(frozen=True, slots=True)
class Enriched:
    device: str | None
    os: str | None
    browser: str | None
    is_bot: bool


def is_bot(user_agent: str | None) -> bool:
    ua = (user_agent or "").strip().lower()
    return not ua or any(m in ua for m in BOT_MARKERS)


def _clean(value: str | None) -> str | None:
    v = (value or "").strip()
    if not v or v.lower() in {"other", "unknown"}:
        return None
    return v[:MAX_LEN]


def _browser_family(family: str | None) -> str | None:
    f = (family or "").strip()
    for prefix in ("Mobile ",):
        f = f.removeprefix(prefix)
    f = f.removesuffix(" Mobile").removesuffix(" Mobile Safari")
    if f in {"Mobile Safari", "Safari Mobile"}:
        f = "Safari"
    return _clean(f)


def _os_family(family: str | None) -> str | None:
    f = (family or "").strip()
    return _clean({"Mac OS X": "macOS"}.get(f, f))


def _device(ua_lower: str, os_family: str | None, device_family: str | None) -> str:
    dev = (device_family or "").lower()
    if "ipad" in dev or "tablet" in dev or "ipad" in ua_lower or "tablet" in ua_lower:
        return "tablet"
    if os_family == "Android":
        return "mobile" if "mobile" in ua_lower else "tablet"
    if os_family == "iOS" or "mobile" in ua_lower or "iphone" in ua_lower:
        return "mobile"
    if os_family and os_family.lower() in _DESKTOP_OS | {"macos"}:
        return "desktop"
    return "other"


@lru_cache(maxsize=_CACHE_SIZE)
def _enrich_cached(ua: str) -> Enriched:
    if is_bot(ua):
        return Enriched("bot", None, None, True)
    r = parse(ua[:_MAX_UA])
    os_f = _os_family(r.os.family if r.os else None)
    dev_f = r.device.family if r.device else None
    return Enriched(
        _device(ua.lower(), os_f, dev_f),
        os_f,
        _browser_family(r.user_agent.family if r.user_agent else None),
        False,
    )


def enrich(user_agent: str | None) -> Enriched:
    """UA → device/os/browser/is_bot. Bots: device="bot", os y browser en None."""
    return _enrich_cached((user_agent or "").strip())
