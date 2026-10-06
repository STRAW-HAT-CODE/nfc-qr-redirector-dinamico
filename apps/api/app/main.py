from collections.abc import AsyncIterator
from contextlib import asynccontextmanager

from fastapi import FastAPI

from app.core.config import get_settings
from app.errors import register_error_handlers
from app.routers import links, orgs, redirect
from app.service_db import build_service_client


@asynccontextmanager
async def lifespan(app: FastAPI) -> AsyncIterator[None]:
    app.state.service_client = build_service_client(get_settings())
    try:
        yield
    finally:
        await app.state.service_client.aclose()


# redirect_slashes=False: Starlette construiría un 307 con la cabecera Host (H2, DQR-T021).
app = FastAPI(title="Dynamic QR API", lifespan=lifespan, redirect_slashes=False)
register_error_handlers(app)
app.include_router(orgs.router)
app.include_router(links.router)
app.include_router(redirect.router)


@app.get("/healthz")
def healthz() -> dict[str, str]:
    return {"status": "ok"}
