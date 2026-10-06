"""Cliente PostgREST con service role. SOLO para el redirector (docs/06-seguridad.md).

Un único `httpx.AsyncClient` compartido (creado en el lifespan) con pool y
timeouts cortos. Nunca usar para endpoints autenticados: allí rige RLS (`UserDB`).
"""

from typing import Any

import httpx

from app.core.config import Settings

_TIMEOUT = httpx.Timeout(connect=1.0, read=2.0, write=1.0, pool=1.0)
_LIMITS = httpx.Limits(max_connections=100, max_keepalive_connections=20)


def build_service_client(settings: Settings) -> httpx.AsyncClient:
    return httpx.AsyncClient(
        base_url=f"{settings.supabase_url.rstrip('/')}/rest/v1",
        headers={
            "apikey": settings.supabase_service_role_key,
            "Authorization": f"Bearer {settings.supabase_service_role_key}",
        },
        timeout=_TIMEOUT,
        limits=_LIMITS,
    )


class ServiceDB:
    """Llamadas RPC con el cliente compartido."""

    def __init__(self, client: httpx.AsyncClient) -> None:
        self._client = client

    async def rpc(self, fn: str, args: dict[str, Any]) -> list[dict[str, Any]]:
        resp = await self._client.post(f"/rpc/{fn}", json=args)
        resp.raise_for_status()
        rows: list[dict[str, Any]] = resp.json()
        return rows
