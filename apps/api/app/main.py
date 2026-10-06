import asyncio
import time
from collections.abc import AsyncIterator
from contextlib import asynccontextmanager

from fastapi import FastAPI, Request

from app.core.config import get_settings
from app.core.logging import AccessLogMiddleware, init_sentry, setup_logging
from app.errors import register_error_handlers
from app.middleware.body_limit import BodyLimitMiddleware
from app.middleware.rate_limit import RateLimitMiddleware, build_rate_limiter
from app.routers import admin, links, me, nfc, orgs, qr, redirect, stats
from app.service_db import ServiceDB, build_service_client


@asynccontextmanager
async def lifespan(app: FastAPI) -> AsyncIterator[None]:
    app.state.service_client = build_service_client(get_settings())
    app.state.rate_limiter = build_rate_limiter(get_settings())
    try:
        yield
    finally:
        await app.state.service_client.aclose()


setup_logging()
init_sentry()

# redirect_slashes=False: Starlette construiría un 307 con la cabecera Host (H2, DQR-T021).
app = FastAPI(title="Dynamic QR API", lifespan=lifespan, redirect_slashes=False)
register_error_handlers(app)
app.add_middleware(RateLimitMiddleware)
app.add_middleware(BodyLimitMiddleware)
app.add_middleware(AccessLogMiddleware)  # el más externo: ve también los 429
app.include_router(me.router)
app.include_router(admin.router)
app.include_router(orgs.router)
app.include_router(links.router)
app.include_router(nfc.router)
app.include_router(qr.router)
app.include_router(stats.router)
app.include_router(redirect.router)


_DB_PING_TIMEOUT_S = 1.0


_DB_PING_TTL_S = 10.0
# (instante monotónico, resultado) del último ping, por instancia; evita amplificar la carga.
_db_ping_cache: tuple[float, bool] | None = None


async def _db_ok(request: Request) -> bool:
    """Ping barato: resolve_link de un slug inexistente (no escribe ni genera eventos).

    El resultado se cachea 10 s por instancia.
    """
    global _db_ping_cache
    now = time.monotonic()
    if _db_ping_cache is not None and now - _db_ping_cache[0] < _DB_PING_TTL_S:
        return _db_ping_cache[1]
    try:
        client = request.app.state.service_client
        async with asyncio.timeout(_DB_PING_TIMEOUT_S):
            await ServiceDB(client).rpc("resolve_link", {"p_slug": "healthz-probe"})
        ok = True
    except Exception:
        ok = False
    _db_ping_cache = (now, ok)
    return ok


@app.get("/healthz")
async def healthz(request: Request) -> dict[str, str]:
    """Siempre 200 mientras el proceso viva; `db: degraded` si la BD no responde.

    No devuelve 5xx por la BD para que los monitores no marquen caído un dominio sano.
    """
    return {
        "status": "ok",
        "version": get_settings().vercel_git_commit_sha or "unknown",
        "db": "ok" if await _db_ok(request) else "degraded",
    }
