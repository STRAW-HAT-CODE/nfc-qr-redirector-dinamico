"""Rate limiting (DQR-T050, docs/06-seguridad.md: abuso y scraping de /r).

- `RateLimiter`: interfaz con dos backends de token bucket: memoria (dev/tests, por
  instancia) y Upstash Redis REST (compartido entre instancias serverless).
- Reglas: /r/* por IP; /v1/* por usuario (sub de un JWT válido) o IP; POST /v1/orgs y
  POST /v1/links además con un límite más estricto. /healthz queda excluido.
- Si el backend compartido falla → fail-open (se loguea): no tumba el redirector.
- La IP sale de `core.net.client_ip` (x-forwarded-for solo con TRUSTED_PROXY_HOPS > 0).
"""

import logging
import math
import time
from dataclasses import dataclass
from typing import Any, Protocol

import httpx
from starlette.requests import Request
from starlette.responses import JSONResponse, Response
from starlette.types import ASGIApp, Message, Receive, Scope, Send

from app.auth import InvalidTokenError, verify_token
from app.core.config import Settings, get_settings
from app.core.net import client_ip

logger = logging.getLogger(__name__)

_MAX_MEMORY_KEYS = 50_000


@dataclass(frozen=True, slots=True)
class Rule:
    name: str
    per_min: int
    burst: int

    @property
    def rate(self) -> float:
        """Tokens por segundo."""
        return self.per_min / 60.0


@dataclass(frozen=True, slots=True)
class Decision:
    allowed: bool
    limit: int
    remaining: int
    retry_after: int  # segundos (≥1 si se rechaza, 0 si se permite)
    reset: int  # segundos hasta recuperar el bucket completo


class RateLimiter(Protocol):
    async def hit(self, key: str, rule: Rule) -> Decision: ...


class MemoryRateLimiter:
    """Token bucket en memoria (por proceso)."""

    def __init__(self, clock: Any = time.monotonic) -> None:
        self._clock = clock
        self._buckets: dict[str, tuple[float, float]] = {}  # key -> (tokens, updated)

    async def hit(self, key: str, rule: Rule) -> Decision:
        now = self._clock()
        tokens, updated = self._buckets.get(key, (float(rule.burst), now))
        tokens = min(float(rule.burst), tokens + (now - updated) * rule.rate)
        allowed = tokens >= 1.0
        if allowed:
            tokens -= 1.0
        self._buckets[key] = (tokens, now)
        if len(self._buckets) > _MAX_MEMORY_KEYS:
            self._evict(now)
        retry = 0 if allowed else max(1, math.ceil((1.0 - tokens) / rule.rate))
        reset = math.ceil((rule.burst - tokens) / rule.rate)
        return Decision(allowed, rule.per_min, int(tokens), retry, reset)

    def _evict(self, now: float) -> None:
        # Descarta buckets inactivos (ya recargados); si no basta, los más antiguos.
        idle = [k for k, (_, u) in self._buckets.items() if now - u > 120]
        for k in idle:
            del self._buckets[k]
        if len(self._buckets) > _MAX_MEMORY_KEYS:
            oldest = sorted(self._buckets, key=lambda k: self._buckets[k][1])
            for k in oldest[: len(oldest) // 2]:
                del self._buckets[k]


# KEYS[1]=bucket; ARGV: burst, rate (tokens/s). Usa TIME de Redis (sin desfase entre instancias).
_LUA = """
local t = redis.call('TIME')
local now = tonumber(t[1]) + tonumber(t[2]) / 1000000
local burst = tonumber(ARGV[1])
local rate = tonumber(ARGV[2])
local s = redis.call('HMGET', KEYS[1], 'tokens', 'ts')
local tokens = tonumber(s[1])
local ts = tonumber(s[2])
if tokens == nil then tokens = burst; ts = now end
tokens = math.min(burst, tokens + math.max(0, now - ts) * rate)
local allowed = 0
if tokens >= 1 then tokens = tokens - 1; allowed = 1 end
redis.call('HSET', KEYS[1], 'tokens', tostring(tokens), 'ts', tostring(now))
redis.call('EXPIRE', KEYS[1], math.ceil(burst / rate) + 60)
return {allowed, math.floor(tokens), math.ceil((burst - tokens) / rate)}
"""


class UpstashRateLimiter:
    """Token bucket compartido vía la API REST de Upstash (EVAL, sin dependencias extra)."""

    def __init__(
        self, url: str, token: str, client: httpx.AsyncClient | None = None, timeout: float = 1.0
    ) -> None:
        self._url = url.rstrip("/")
        self._headers = {"Authorization": f"Bearer {token}"}
        self._client = client or httpx.AsyncClient(timeout=timeout)

    async def hit(self, key: str, rule: Rule) -> Decision:
        resp = await self._client.post(
            self._url,
            headers=self._headers,
            json=["EVAL", _LUA, "1", f"rl:{key}", str(rule.burst), repr(rule.rate)],
        )
        resp.raise_for_status()
        body = resp.json()
        if "error" in body:
            raise RuntimeError("upstash error")
        allowed, remaining, reset = (int(x) for x in body["result"])
        retry = 0 if allowed else max(1, math.ceil(1.0 / rule.rate))
        return Decision(bool(allowed), rule.per_min, remaining, retry, reset)


def build_rate_limiter(settings: Settings) -> RateLimiter:
    if settings.upstash_redis_rest_url and settings.upstash_redis_rest_token:
        return UpstashRateLimiter(
            settings.upstash_redis_rest_url, settings.upstash_redis_rest_token
        )
    logger.warning("Upstash no configurado: rate limiting en memoria (por instancia)")
    return MemoryRateLimiter()


def _headers(d: Decision) -> dict[str, str]:
    return {
        "RateLimit-Limit": str(d.limit),
        "RateLimit-Remaining": str(d.remaining),
        "RateLimit-Reset": str(d.reset),
    }


def _redirect_429(head: bool, headers: dict[str, str]) -> Response:
    html = (
        '<!doctype html><html lang="es"><head><meta charset="utf-8">'
        '<meta name="viewport" content="width=device-width,initial-scale=1">'
        '<meta name="robots" content="noindex"><title>Demasiadas solicitudes</title></head>'
        '<body style="font-family:system-ui,sans-serif;text-align:center;padding:4rem 1rem">'
        "<h1>Demasiadas solicitudes</h1><p>Intenta de nuevo en unos segundos.</p></body></html>"
    )
    return Response(
        content=b"" if head else html,
        status_code=429,
        media_type="text/html",
        headers={**headers, "Cache-Control": "no-store"},
    )


class RateLimitMiddleware:
    """Middleware ASGI puro (no interfiere con BackgroundTasks ni streaming)."""

    def __init__(self, app: ASGIApp, limiter: RateLimiter | None = None) -> None:
        self.app = app
        self._limiter = limiter

    def _get_limiter(self, scope: Scope, settings: Settings) -> RateLimiter:
        """Limiter de `app.state` (lo crea el lifespan); si falta, uno propio perezoso."""
        if self._limiter is not None:
            return self._limiter
        state = scope["app"].state if "app" in scope else None
        limiter = getattr(state, "rate_limiter", None)
        if limiter is None:
            limiter = build_rate_limiter(settings)
            if state is not None:
                state.rate_limiter = limiter
        return limiter

    async def _user_or_ip_key(self, request: Request, settings: Settings) -> str:
        auth = request.headers.get("authorization", "")
        scheme, _, token = auth.partition(" ")
        if scheme.lower() == "bearer" and token.strip():
            try:
                user = await verify_token(token.strip(), settings)
                return f"u:{user.id}"
            except InvalidTokenError:
                pass
            except Exception:  # JWKS caído, etc.: se degrada a IP
                logger.warning("verificación de JWT para rate limit falló", exc_info=True)
        return f"ip:{client_ip(request, settings.trusted_proxy_hops) or 'unknown'}"

    def _rules(self, request: Request, settings: Settings) -> list[tuple[str, Rule]] | None:
        """(tipo de clave, regla) a aplicar; None = sin límite."""
        path = request.url.path
        if path == "/r" or path.startswith("/r/"):
            rule = Rule(
                "redirect", settings.rate_limit_redirect_per_min, settings.rate_limit_redirect_burst
            )
            return [("ip", rule)]
        if path == "/v1" or path.startswith("/v1/"):
            rules = [
                (
                    "user",
                    Rule("api", settings.rate_limit_api_per_min, settings.rate_limit_api_burst),
                )
            ]
            if request.method == "POST" and path in {"/v1/orgs", "/v1/links"}:
                strict = Rule(
                    f"strict:{path}",
                    settings.rate_limit_strict_per_min,
                    settings.rate_limit_strict_burst,
                )
                rules.append(("user", strict))
            return rules
        return None

    async def __call__(self, scope: Scope, receive: Receive, send: Send) -> None:
        if scope["type"] != "http":
            await self.app(scope, receive, send)
            return
        settings = get_settings()
        request = Request(scope)
        rules = self._rules(request, settings) if settings.rate_limit_enabled else None
        if not rules or request.method == "OPTIONS":
            await self.app(scope, receive, send)
            return

        decision: Decision | None = None
        try:
            limiter = self._get_limiter(scope, settings)
            base_key = (
                f"ip:{client_ip(request, settings.trusted_proxy_hops) or 'unknown'}"
                if rules[0][0] == "ip"
                else await self._user_or_ip_key(request, settings)
            )
            for _, rule in rules:
                d = await limiter.hit(f"{rule.name}|{base_key}", rule)
                if not d.allowed:
                    decision = d
                    break
                if decision is None or d.remaining < decision.remaining:
                    decision = d
        except Exception:
            logger.warning("rate limiter falló; fail-open", exc_info=True)
            await self.app(scope, receive, send)
            return

        assert decision is not None
        headers = _headers(decision)
        if not decision.allowed:
            headers["Retry-After"] = str(decision.retry_after)
            response: Response
            if rules[0][1].name == "redirect":
                response = _redirect_429(request.method == "HEAD", headers)
            else:
                response = JSONResponse(
                    status_code=429,
                    content={
                        "error": {
                            "code": "rate_limited",
                            "message": "Demasiadas solicitudes; intenta más tarde.",
                        }
                    },
                    headers=headers,
                )
            await response(scope, receive, send)
            return

        async def send_with_headers(message: Message) -> None:
            if message["type"] == "http.response.start":
                raw = list(message.get("headers", []))
                raw += [(k.lower().encode(), v.encode()) for k, v in headers.items()]
                message = {**message, "headers": raw}
            await send(message)

        await self.app(scope, receive, send_with_headers)
