"""Cliente PostgREST por petición con el JWT del usuario (RLS). Nunca service role."""

from typing import Any

import httpx

from app.core.config import Settings


class UserDB:
    """Consulta PostgREST con `Authorization: Bearer <jwt del usuario>`."""

    def __init__(self, settings: Settings, user_token: str) -> None:
        self._client = httpx.AsyncClient(
            base_url=f"{settings.supabase_url.rstrip('/')}/rest/v1",
            headers={
                "apikey": settings.supabase_anon_key,
                "Authorization": f"Bearer {user_token}",
            },
            timeout=10.0,
        )

    async def select(self, table: str, params: dict[str, str]) -> list[dict[str, Any]]:
        resp = await self._client.get(f"/{table}", params=params)
        resp.raise_for_status()
        rows: list[dict[str, Any]] = resp.json()
        return rows

    async def aclose(self) -> None:
        await self._client.aclose()
