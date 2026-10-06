import asyncio
import time
from collections.abc import Iterator
from typing import Any

import httpx
import jwt
import pytest
import respx
from fastapi import FastAPI
from fastapi.testclient import TestClient

from app.core.config import get_settings
from app.errors import register_error_handlers
from app.middleware.rate_limit import (
    MemoryRateLimiter,
    RateLimitMiddleware,
    Rule,
    UpstashRateLimiter,
)

BASE = "https://proj.supabase.co"
SECRET = "s" * 40


@pytest.fixture(autouse=True)
def _env(monkeypatch: pytest.MonkeyPatch) -> Iterator[None]:
    monkeypatch.setenv("SUPABASE_URL", BASE)
    monkeypatch.setenv("SUPABASE_JWT_SECRET", SECRET)
    monkeypatch.setenv("RATE_LIMIT_REDIRECT_BURST", "3")
    monkeypatch.setenv("RATE_LIMIT_REDIRECT_PER_MIN", "60")
    monkeypatch.setenv("RATE_LIMIT_API_BURST", "2")
    monkeypatch.setenv("RATE_LIMIT_API_PER_MIN", "60")
    monkeypatch.setenv("RATE_LIMIT_STRICT_BURST", "1")
    monkeypatch.setenv("RATE_LIMIT_STRICT_PER_MIN", "6")
    monkeypatch.delenv("TRUSTED_PROXY_HOPS", raising=False)
    get_settings.cache_clear()
    yield
    get_settings.cache_clear()


def token(sub: str) -> str:
    claims = {
        "sub": sub,
        "aud": "authenticated",
        "iss": f"{BASE}/auth/v1",
        "exp": int(time.time()) + 600,
    }
    return jwt.encode(claims, SECRET, algorithm="HS256")


def make_app(limiter: Any = None) -> FastAPI:
    app = FastAPI(redirect_slashes=False)
    register_error_handlers(app)
    app.add_middleware(RateLimitMiddleware, limiter=limiter)

    @app.get("/r/{slug}")
    def r(slug: str) -> dict[str, str]:
        return {"ok": slug}

    @app.get("/v1/things")
    def things() -> dict[str, str]:
        return {"ok": "1"}

    @app.post("/v1/orgs")
    def orgs() -> dict[str, str]:
        return {"ok": "1"}

    @app.get("/healthz")
    def healthz() -> dict[str, str]:
        return {"status": "ok"}

    return app


def bearer(sub: str) -> dict[str, str]:
    return {"Authorization": f"Bearer {token(sub)}"}


def test_under_limit_ok_with_headers() -> None:
    c = TestClient(make_app())
    r = c.get("/v1/things", headers=bearer("u1"))
    assert r.status_code == 200
    assert r.headers["RateLimit-Limit"] == "60"
    assert r.headers["RateLimit-Remaining"] == "1"
    assert "RateLimit-Reset" in r.headers


def test_burst_then_429_json_with_headers() -> None:
    c = TestClient(make_app())
    for _ in range(2):
        assert c.get("/v1/things", headers=bearer("u1")).status_code == 200
    r = c.get("/v1/things", headers=bearer("u1"))
    assert r.status_code == 429
    assert r.json()["error"]["code"] == "rate_limited"
    assert int(r.headers["Retry-After"]) >= 1
    assert r.headers["RateLimit-Remaining"] == "0"
    assert "RateLimit-Limit" in r.headers and "RateLimit-Reset" in r.headers


def test_redirect_429_is_html_no_store() -> None:
    c = TestClient(make_app())
    for _ in range(3):
        assert c.get("/r/abc").status_code == 200
    r = c.get("/r/abc")
    assert r.status_code == 429
    assert r.headers["content-type"].startswith("text/html")
    assert r.headers["cache-control"] == "no-store"
    assert "Retry-After" in r.headers
    assert "Demasiadas solicitudes" in r.text


def test_separate_keys_per_user_and_ip() -> None:
    c = TestClient(make_app())
    for _ in range(2):
        c.get("/v1/things", headers=bearer("u1"))
    assert c.get("/v1/things", headers=bearer("u1")).status_code == 429
    assert c.get("/v1/things", headers=bearer("u2")).status_code == 200  # otro usuario
    # Sin token → clave por IP, independiente de los usuarios.
    assert c.get("/v1/things").status_code == 200


def test_invalid_token_falls_back_to_ip() -> None:
    c = TestClient(make_app())
    bad = {"Authorization": "Bearer nope"}
    assert c.get("/v1/things", headers=bad).status_code == 200
    assert c.get("/v1/things", headers=bad).status_code == 200
    assert c.get("/v1/things", headers=bad).status_code == 429


def test_strict_limit_on_post_orgs() -> None:
    c = TestClient(make_app())
    h = bearer("u1")
    assert c.post("/v1/orgs", headers=h).status_code == 200
    r = c.post("/v1/orgs", headers=h)
    assert r.status_code == 429
    assert r.json()["error"]["code"] == "rate_limited"
    # Otro usuario no se ve afectado.
    assert c.post("/v1/orgs", headers=bearer("u2")).status_code == 200


def test_healthz_excluded() -> None:
    c = TestClient(make_app())
    for _ in range(20):
        assert c.get("/healthz").status_code == 200


def test_xff_ignored_with_zero_hops_and_used_with_one(monkeypatch: pytest.MonkeyPatch) -> None:
    c = TestClient(make_app())
    for i in range(3):
        assert c.get("/r/a", headers={"x-forwarded-for": f"1.1.1.{i}"}).status_code == 200
    # 0 hops: rotar x-forwarded-for no evade el límite.
    assert c.get("/r/a", headers={"x-forwarded-for": "9.9.9.9"}).status_code == 429

    monkeypatch.setenv("TRUSTED_PROXY_HOPS", "1")
    get_settings.cache_clear()
    c = TestClient(make_app())
    for _ in range(3):
        assert c.get("/r/a", headers={"x-forwarded-for": "1.1.1.1"}).status_code == 200
    assert c.get("/r/a", headers={"x-forwarded-for": "1.1.1.1"}).status_code == 429
    assert c.get("/r/a", headers={"x-forwarded-for": "2.2.2.2"}).status_code == 200


def test_disabled_flag(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("RATE_LIMIT_ENABLED", "false")
    get_settings.cache_clear()
    c = TestClient(make_app())
    for _ in range(10):
        assert c.get("/r/a").status_code == 200


class BrokenLimiter:
    async def hit(self, key: str, rule: Rule) -> Any:
        raise RuntimeError("redis down")


def test_limiter_failure_is_fail_open(caplog: pytest.LogCaptureFixture) -> None:
    c = TestClient(make_app(BrokenLimiter()))
    for _ in range(10):
        assert c.get("/r/a").status_code == 200
    assert "fail-open" in caplog.text


@respx.mock
def test_upstash_down_is_fail_open() -> None:
    url = "https://redis.example.upstash.io"
    respx.post(url).mock(side_effect=httpx.ConnectError("boom"))
    c = TestClient(make_app(UpstashRateLimiter(url, "tok")))
    for _ in range(10):
        assert c.get("/v1/things").status_code == 200


@respx.mock
def test_upstash_backend_decision_and_auth() -> None:
    url = "https://redis.example.upstash.io"
    route = respx.post(url).mock(
        side_effect=[
            httpx.Response(200, json={"result": [1, 4, 3]}),
            httpx.Response(200, json={"result": [0, 0, 20]}),
        ]
    )
    c = TestClient(make_app(UpstashRateLimiter(url, "tok")))
    ok = c.get("/r/a")
    assert ok.status_code == 200 and ok.headers["RateLimit-Remaining"] == "4"
    blocked = c.get("/r/a")
    assert blocked.status_code == 429
    assert blocked.headers["Retry-After"] == "1"
    assert route.calls[0].request.headers["authorization"] == "Bearer tok"


def test_memory_limiter_refills_over_time() -> None:
    asyncio.run(_refill())


async def _refill() -> None:
    now = [0.0]
    lim = MemoryRateLimiter(clock=lambda: now[0])
    rule = Rule("t", 60, 2)  # 1 token/s
    assert (await lim.hit("k", rule)).allowed
    assert (await lim.hit("k", rule)).allowed
    d = await lim.hit("k", rule)
    assert not d.allowed and d.retry_after == 1
    now[0] += 1.0
    assert (await lim.hit("k", rule)).allowed
    assert not (await lim.hit("k", rule)).allowed


def test_real_app_healthz_and_redirect_429(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("SUPABASE_SERVICE_ROLE_KEY", "k")
    get_settings.cache_clear()
    from app.main import app

    with TestClient(app, follow_redirects=False) as c:
        with respx.mock:
            respx.post(f"{BASE}/rest/v1/rpc/resolve_link").mock(
                return_value=httpx.Response(200, json=[])
            )
            codes = [c.get("/r/aB3dE5g").status_code for _ in range(5)]
        assert codes[:3] == [404, 404, 404] and codes[3] == 429
        assert c.get("/healthz").status_code == 200
