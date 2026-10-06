import time
from collections.abc import Iterator
from datetime import UTC, datetime, timedelta
from typing import Any

import httpx
import pytest
import respx
from fastapi.testclient import TestClient

from app.core.config import get_settings
from app.main import app
from app.routers import redirect as redirect_mod

BASE = "https://proj.supabase.co"
RPC = f"{BASE}/rest/v1/rpc/resolve_link"
SLUG = "aB3dE5g"
DEST = "https://example.com/dest"
FALLBACK = "https://example.com/fallback"


@pytest.fixture(autouse=True)
def _env(monkeypatch: pytest.MonkeyPatch) -> Iterator[None]:
    monkeypatch.setenv("SUPABASE_URL", BASE)
    monkeypatch.setenv("SUPABASE_SERVICE_ROLE_KEY", "service-key")
    get_settings.cache_clear()
    yield
    get_settings.cache_clear()


@pytest.fixture
def client() -> Iterator[TestClient]:
    with TestClient(app, follow_redirects=False) as c:  # ejecuta el lifespan
        yield c


def row(**kw: Any) -> dict[str, Any]:
    base: dict[str, Any] = {
        "id": "00000000-0000-0000-0000-000000000001",
        "org_id": "00000000-0000-0000-0000-000000000002",
        "destination_url": DEST,
        "fallback_url": None,
        "status": "active",
        "starts_at": None,
        "expires_at": None,
        "org_status": "active",
    }
    return base | kw


def iso(delta_h: int) -> str:
    return (datetime.now(UTC) + timedelta(hours=delta_h)).isoformat()


def mock_rows(rows: list[dict[str, Any]]) -> respx.Route:
    return respx.post(RPC).mock(return_value=httpx.Response(200, json=rows))


def assert_safe(r: httpx.Response) -> None:
    assert r.headers["cache-control"] == "no-store"
    assert r.status_code != 301
    assert "set-cookie" not in r.headers


@respx.mock
def test_active_redirects_302(client: TestClient) -> None:
    route = mock_rows([row()])
    r = client.get(f"/r/{SLUG}")
    assert r.status_code == 302
    assert r.headers["location"] == DEST
    assert_safe(r)
    req = route.calls.last.request
    assert req.headers["apikey"] == "service-key"
    assert req.content == b'{"p_slug":"aB3dE5g"}'


@respx.mock
@pytest.mark.parametrize(
    "overrides",
    [
        {"status": "paused"},
        {"status": "archived"},
        {"expires_at": iso(-1)},
        {"starts_at": iso(1)},
    ],
)
def test_not_live_goes_to_fallback(client: TestClient, overrides: dict[str, Any]) -> None:
    mock_rows([row(fallback_url=FALLBACK, **overrides)])
    r = client.get(f"/r/{SLUG}")
    assert r.status_code == 302
    assert r.headers["location"] == FALLBACK
    assert_safe(r)


@respx.mock
@pytest.mark.parametrize(
    "overrides",
    [{"status": "paused"}, {"status": "archived"}, {"expires_at": iso(-1)}, {"starts_at": iso(1)}],
)
def test_not_live_without_fallback_is_unavailable_page(
    client: TestClient, overrides: dict[str, Any]
) -> None:
    mock_rows([row(**overrides)])
    r = client.get(f"/r/{SLUG}")
    assert r.status_code == 200
    assert "location" not in r.headers
    assert "no está disponible" in r.text
    assert_safe(r)


@respx.mock
def test_vigente_with_dates_redirects(client: TestClient) -> None:
    mock_rows([row(starts_at=iso(-2), expires_at=iso(2))])
    assert client.get(f"/r/{SLUG}").status_code == 302


@respx.mock
def test_suspended_org_is_unavailable_even_with_fallback(client: TestClient) -> None:
    mock_rows([row(org_status="suspended", fallback_url=FALLBACK)])
    r = client.get(f"/r/{SLUG}")
    assert r.status_code == 200
    assert "location" not in r.headers
    assert_safe(r)


@respx.mock
def test_unknown_slug_is_friendly_404(client: TestClient) -> None:
    mock_rows([])
    r = client.get(f"/r/{SLUG}")
    assert r.status_code == 404
    assert "no encontramos" in r.text.lower()
    assert r.headers["content-type"].startswith("text/html")
    assert_safe(r)


@respx.mock
@pytest.mark.parametrize("slug", ["short", "aB3dE5g9", "aB3dE5!", "ñB3dE5g", "aB3d-5g"])
def test_invalid_slug_404_without_db(client: TestClient, slug: str) -> None:
    route = mock_rows([row()])
    r = client.get(f"/r/{slug}")
    assert r.status_code == 404
    assert not route.called
    assert_safe(r)


@respx.mock
def test_query_params_never_affect_destination(client: TestClient) -> None:
    mock_rows([row()])
    r = client.get(f"/r/{SLUG}?url=https://evil.com&c=q&t=x&next=//evil.com&redirect=evil")
    assert r.status_code == 302
    assert r.headers["location"] == DEST


@respx.mock
def test_params_passed_to_on_scan(client: TestClient, monkeypatch: pytest.MonkeyPatch) -> None:
    seen: list[tuple[redirect_mod.Channel, str | None]] = []

    async def spy(link: Any, channel: Any, tag: Any, request: Any) -> None:
        seen.append((channel, tag))

    monkeypatch.setattr(redirect_mod, "on_scan", spy)
    mock_rows([row()])
    client.get(f"/r/{SLUG}?c=n&t=tag1")
    client.get(f"/r/{SLUG}?c=zzz&t=" + "x" * 200)
    client.get(f"/r/{SLUG}")
    assert seen == [
        (redirect_mod.Channel.NFC, "tag1"),
        (redirect_mod.Channel.DIRECT, None),
        (redirect_mod.Channel.DIRECT, None),
    ]


@respx.mock
def test_on_scan_failure_does_not_break_redirect(
    client: TestClient, monkeypatch: pytest.MonkeyPatch
) -> None:
    async def boom(*_: Any) -> None:
        raise RuntimeError("fallo")

    monkeypatch.setattr(redirect_mod, "on_scan", boom)
    mock_rows([row()])
    r = client.get(f"/r/{SLUG}")
    assert r.status_code == 302


@respx.mock
@pytest.mark.parametrize(
    "side_effect",
    [
        httpx.ConnectTimeout("t"),
        httpx.ReadTimeout("t"),
        httpx.ConnectError("c"),
        httpx.Response(500, text="secret db detail"),
        httpx.Response(200, text="not json"),
    ],
)
def test_db_failure_is_503_without_leaking(client: TestClient, side_effect: Any) -> None:
    respx.post(RPC).mock(side_effect=[side_effect])
    r = client.get(f"/r/{SLUG}")
    assert r.status_code == 503
    assert "secret" not in r.text and "supabase" not in r.text.lower()
    assert "location" not in r.headers
    assert_safe(r)


@respx.mock
def test_malformed_row_is_503(client: TestClient) -> None:
    mock_rows([{"status": "active"}])
    assert client.get(f"/r/{SLUG}").status_code == 503


@respx.mock
def test_head_same_behavior_without_body(client: TestClient) -> None:
    mock_rows([row()])
    r = client.head(f"/r/{SLUG}")
    assert r.status_code == 302 and r.headers["location"] == DEST
    assert_safe(r)

    mock_rows([row(status="paused")])
    r = client.head(f"/r/{SLUG}")
    assert r.status_code == 200 and r.content == b""

    mock_rows([])
    r = client.head(f"/r/{SLUG}")
    assert r.status_code == 404 and r.content == b""

    respx.post(RPC).mock(side_effect=httpx.ConnectError("x"))
    assert client.head(f"/r/{SLUG}").status_code == 503


@respx.mock
def test_handler_latency_reference(client: TestClient) -> None:
    """Referencia: latencia del handler con la BD mockeada (no es un SLO)."""
    mock_rows([row()])
    client.get(f"/r/{SLUG}")  # calentamiento
    samples = []
    for _ in range(200):
        t0 = time.perf_counter()
        client.get(f"/r/{SLUG}")
        samples.append((time.perf_counter() - t0) * 1000)
    samples.sort()
    print(f"latency ms p50={samples[100]:.2f} p95={samples[190]:.2f}")
    assert samples[190] < 150
