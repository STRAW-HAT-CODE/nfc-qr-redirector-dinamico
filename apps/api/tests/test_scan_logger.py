import json
from collections.abc import Iterator
from datetime import UTC, datetime
from typing import Any

import httpx
import pytest
import respx
from fastapi.testclient import TestClient

from app.core.config import get_settings
from app.main import app
from app.services import scan_logger
from app.services.scan_logger import _norm_ip, hash_ip, parse_country, referer_origin

BASE = "https://proj.supabase.co"
RESOLVE = f"{BASE}/rest/v1/rpc/resolve_link"
RECORD = f"{BASE}/rest/v1/rpc/record_scan"
SLUG = "aB3dE5g"
LINK_ID = "00000000-0000-0000-0000-000000000001"
ORG_ID = "00000000-0000-0000-0000-000000000002"
TAG = "11111111-2222-3333-4444-555555555555"
UA = {"user-agent": "Mozilla/5.0 (iPhone)"}


def row(**kw: Any) -> dict[str, Any]:
    base: dict[str, Any] = {
        "id": LINK_ID,
        "org_id": ORG_ID,
        "destination_url": "https://example.com/d",
        "fallback_url": None,
        "status": "active",
        "starts_at": None,
        "expires_at": None,
        "org_status": "active",
    }
    return base | kw


@pytest.fixture(autouse=True)
def _env(monkeypatch: pytest.MonkeyPatch) -> Iterator[None]:
    monkeypatch.setenv("SUPABASE_URL", BASE)
    monkeypatch.setenv("SUPABASE_SERVICE_ROLE_KEY", "service-key")
    monkeypatch.setenv("IP_HASH_SALT", "pepper")
    monkeypatch.delenv("TRUSTED_PROXY_HOPS", raising=False)
    get_settings.cache_clear()
    yield
    get_settings.cache_clear()


@pytest.fixture
def client() -> Iterator[TestClient]:
    with TestClient(app, follow_redirects=False, client=("203.0.113.5", 50000)) as c:
        yield c


def setup_routes(link: dict[str, Any] | None = None) -> respx.Route:
    respx.post(RESOLVE).mock(return_value=httpx.Response(200, json=[link or row()]))
    return respx.post(RECORD).mock(return_value=httpx.Response(200, json=1))


def payload(route: respx.Route) -> dict[str, Any]:
    assert route.call_count == 1
    return json.loads(route.calls.last.request.content)


@respx.mock
@pytest.mark.parametrize(
    ("query", "channel"), [("?c=q", "qr"), ("?c=n", "nfc"), ("", "direct"), ("?c=zz", "direct")]
)
def test_payload_per_channel(client: TestClient, query: str, channel: str) -> None:
    rec = setup_routes()
    r = client.get(f"/r/{SLUG}{query}", headers=UA)
    assert r.status_code == 302
    p = payload(rec)
    assert p["p_link_id"] == LINK_ID
    assert p["p_org_id"] == ORG_ID
    assert p["p_channel"] == channel
    assert p["p_tag_id"] is None
    assert p["p_device"] is None and p["p_os"] is None and p["p_browser"] is None
    assert p["p_is_bot"] is False
    assert len(p["p_ip_hash"]) == 64


@respx.mock
def test_tag_uuid_only_with_nfc(client: TestClient) -> None:
    rec = setup_routes()
    client.get(f"/r/{SLUG}?c=n&t={TAG}", headers=UA)
    assert payload(rec)["p_tag_id"] == TAG


@respx.mock
def test_tag_ignored_on_other_channels(client: TestClient) -> None:
    rec = setup_routes()
    client.get(f"/r/{SLUG}?c=q&t={TAG}", headers=UA)
    assert payload(rec)["p_tag_id"] is None


@respx.mock
def test_invalid_tag_is_null(client: TestClient) -> None:
    rec = setup_routes()
    client.get(f"/r/{SLUG}?c=n&t=not-a-uuid", headers=UA)
    assert payload(rec)["p_tag_id"] is None


def test_ip_hash_deterministic_per_day_and_differs_between_days() -> None:
    d1 = datetime(2026, 10, 5, 23, 59, tzinfo=UTC)
    d2 = datetime(2026, 10, 6, 0, 1, tzinfo=UTC)
    a = hash_ip("1.2.3.4", "salt", d1)
    assert a == hash_ip("1.2.3.4", "salt", d1)
    assert a != hash_ip("1.2.3.4", "salt", d2)
    assert a != hash_ip("1.2.3.5", "salt", d1)
    assert a is not None
    assert len(a) == 64
    assert "1.2.3.4" not in a


def test_missing_salt_gives_null_and_warns_once(caplog: pytest.LogCaptureFixture) -> None:
    scan_logger._warned_no_salt = False
    with caplog.at_level("WARNING"):
        assert hash_ip("1.2.3.4", "") is None
        assert hash_ip("1.2.3.4", "") is None
    assert sum("IP_HASH_SALT" in m for m in caplog.messages) == 1


@respx.mock
def test_xff_ignored_with_zero_hops(client: TestClient) -> None:
    rec = setup_routes()
    client.get(f"/r/{SLUG}", headers=UA | {"x-forwarded-for": "9.9.9.9"})
    client.get(f"/r/{SLUG}", headers=UA | {"x-forwarded-for": "8.8.8.8"})
    a, b = (json.loads(c.request.content)["p_ip_hash"] for c in rec.calls)
    assert a == b  # misma IP de conexión; la cabecera no cuenta


@respx.mock
def test_xff_used_with_trusted_hop(client: TestClient, monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("TRUSTED_PROXY_HOPS", "1")
    get_settings.cache_clear()
    rec = setup_routes()
    client.get(f"/r/{SLUG}", headers=UA | {"x-forwarded-for": "6.6.6.6, 9.9.9.9"})
    client.get(f"/r/{SLUG}", headers=UA | {"x-forwarded-for": "7.7.7.7, 9.9.9.9"})
    a, b = (json.loads(c.request.content)["p_ip_hash"] for c in rec.calls)
    assert a == b  # cuenta desde la derecha: el cliente no puede falsearlo


@respx.mock
def test_no_salt_ip_hash_null(client: TestClient, monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("IP_HASH_SALT", "")
    get_settings.cache_clear()
    rec = setup_routes()
    client.get(f"/r/{SLUG}", headers=UA)
    assert payload(rec)["p_ip_hash"] is None


@pytest.mark.parametrize(
    ("raw", "expected"),
    [
        ("https://a.com/path?token=1#f", "https://a.com"),
        ("http://user:pw@a.com:8080/x", "http://a.com:8080"),
        ("https://[::1]:9/x", "https://[::1]:9"),
        ("javascript:alert(1)", None),
        ("not a url", None),
        ("", None),
        (None, None),
    ],
)
def test_referer_origin(raw: str | None, expected: str | None) -> None:
    assert referer_origin(raw) == expected


@respx.mock
def test_referer_reduced_in_request(client: TestClient) -> None:
    rec = setup_routes()
    client.get(f"/r/{SLUG}", headers=UA | {"referer": "https://a.com/p?secret=1"})
    assert payload(rec)["p_referer"] == "https://a.com"


@pytest.mark.parametrize(
    ("raw", "expected"), [("EC", "EC"), ("ec", "EC"), ("ECU", None), ("1A", None), ("", None)]
)
def test_country(raw: str, expected: str | None) -> None:
    assert parse_country(raw) == expected


@respx.mock
def test_country_header_invalid(client: TestClient, monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("TRUSTED_PROXY_HOPS", "1")
    get_settings.cache_clear()
    rec = setup_routes()
    client.get(f"/r/{SLUG}", headers=UA | {"x-vercel-ip-country": "ZZZ"})
    assert payload(rec)["p_country"] is None


@respx.mock
def test_country_header_used_only_with_trusted_proxy(
    client: TestClient, monkeypatch: pytest.MonkeyPatch
) -> None:
    rec = setup_routes()
    client.get(f"/r/{SLUG}", headers=UA | {"x-vercel-ip-country": "EC"})
    assert payload(rec)["p_country"] is None  # 0 hops: la cabecera la controla el cliente
    monkeypatch.setenv("TRUSTED_PROXY_HOPS", "1")
    get_settings.cache_clear()
    rec2 = setup_routes()
    client.get(f"/r/{SLUG}", headers=UA | {"x-vercel-ip-country": "EC"})
    assert json.loads(rec2.calls.last.request.content)["p_country"] == "EC"


@pytest.mark.parametrize(
    ("raw", "expected"),
    [
        ("1.2.3.4", "1.2.3.4"),
        ("::ffff:1.2.3.4", "1.2.3.4"),
        ("2001:DB8::1", "2001:db8::1"),
        ("2001:db8:0:0::1", "2001:db8::1"),
        ("1.2.3.4:5555", None),
        ("garbage", None),
        ("", None),
        (None, None),
    ],
)
def test_norm_ip(raw: str | None, expected: str | None) -> None:
    assert _norm_ip(raw) == expected


@respx.mock
def test_ipv6_variants_same_hash_and_garbage_null(
    client: TestClient, monkeypatch: pytest.MonkeyPatch
) -> None:
    monkeypatch.setenv("TRUSTED_PROXY_HOPS", "1")
    get_settings.cache_clear()
    rec = setup_routes()
    for xff in ("2001:DB8::1", "2001:db8:0:0::1", "garbage"):
        client.get(f"/r/{SLUG}", headers=UA | {"x-forwarded-for": xff})
    a, b, c = (json.loads(x.request.content)["p_ip_hash"] for x in rec.calls)
    assert a == b
    assert a is not None
    assert c is None


@respx.mock
@pytest.mark.parametrize("ua", ["curl/8", "Googlebot/2.1", "Slackbot link preview"])
def test_bot_heuristic(client: TestClient, ua: str) -> None:
    rec = setup_routes()
    client.get(f"/r/{SLUG}", headers={"user-agent": ua})
    assert payload(rec)["p_is_bot"] is True


@respx.mock
def test_empty_ua_is_bot(client: TestClient) -> None:
    rec = setup_routes()
    client.get(f"/r/{SLUG}", headers={"user-agent": ""})
    assert payload(rec)["p_is_bot"] is True


@respx.mock
def test_rpc_error_keeps_302(client: TestClient, caplog: pytest.LogCaptureFixture) -> None:
    respx.post(RESOLVE).mock(return_value=httpx.Response(200, json=[row()]))
    respx.post(RECORD).mock(return_value=httpx.Response(500, json={"message": "boom"}))
    r = client.get(f"/r/{SLUG}", headers=UA)
    assert r.status_code == 302
    assert "testclient" not in caplog.text


@respx.mock
def test_rpc_timeout_keeps_302(client: TestClient) -> None:
    respx.post(RESOLVE).mock(return_value=httpx.Response(200, json=[row()]))
    respx.post(RECORD).mock(side_effect=httpx.ReadTimeout("slow"))
    assert client.get(f"/r/{SLUG}", headers=UA).status_code == 302


@respx.mock
def test_asyncio_timeout_keeps_302(client: TestClient, monkeypatch: pytest.MonkeyPatch) -> None:
    import asyncio

    monkeypatch.setattr(scan_logger, "_TIMEOUT_S", 0.05)

    async def slow(request: httpx.Request) -> httpx.Response:
        await asyncio.sleep(1)
        return httpx.Response(200, json=1)

    respx.post(RESOLVE).mock(return_value=httpx.Response(200, json=[row()]))
    respx.post(RECORD).mock(side_effect=slow)
    assert client.get(f"/r/{SLUG}", headers=UA).status_code == 302


@respx.mock
def test_head_does_not_record(client: TestClient) -> None:
    rec = setup_routes()
    assert client.head(f"/r/{SLUG}").status_code == 302
    assert rec.call_count == 0


@respx.mock
def test_suspended_org_not_recorded(client: TestClient) -> None:
    rec = setup_routes(row(org_status="suspended"))
    client.get(f"/r/{SLUG}", headers=UA)
    assert rec.call_count == 0


@respx.mock
def test_unknown_link_not_recorded(client: TestClient) -> None:
    respx.post(RESOLVE).mock(return_value=httpx.Response(200, json=[]))
    rec = respx.post(RECORD).mock(return_value=httpx.Response(200, json=1))
    assert client.get(f"/r/{SLUG}", headers=UA).status_code == 404
    assert rec.call_count == 0


@respx.mock
@pytest.mark.parametrize("status", ["paused", "archived"])
def test_paused_and_archived_are_recorded(client: TestClient, status: str) -> None:
    rec = setup_routes(row(status=status))
    client.get(f"/r/{SLUG}", headers=UA)
    assert rec.call_count == 1


@respx.mock
def test_expired_is_recorded(client: TestClient) -> None:
    rec = setup_routes(row(expires_at="2020-01-01T00:00:00+00:00"))
    client.get(f"/r/{SLUG}", headers=UA)
    assert rec.call_count == 1
