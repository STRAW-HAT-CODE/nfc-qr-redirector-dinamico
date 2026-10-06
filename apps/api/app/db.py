"""Cliente PostgREST por petición con el JWT del usuario (RLS). Nunca service role."""

from typing import Any

import httpx

from app.core.config import Settings


class PostgrestError(Exception):
    """Error 4xx de PostgREST/BD (código SQLSTATE, mensaje y hint)."""

    def __init__(self, status: int, code: str, message: str, hint: str | None = None) -> None:
        super().__init__(f"{status} {code}: {message}")
        self.status = status
        self.code = code
        self.message = message
        self.hint = hint


def _check(resp: httpx.Response) -> None:
    """4xx => PostgrestError con el cuerpo parseado; 5xx => httpx.HTTPStatusError."""
    if 400 <= resp.status_code < 500:
        try:
            body = resp.json()
        except ValueError:
            body = {}
        if not isinstance(body, dict):
            body = {}
        raise PostgrestError(
            resp.status_code,
            str(body.get("code") or ""),
            str(body.get("message") or ""),
            body.get("hint"),
        )
    resp.raise_for_status()


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

    async def insert(self, table: str, row: dict[str, Any]) -> list[dict[str, Any]]:
        resp = await self._client.post(
            f"/{table}", json=row, headers={"Prefer": "return=representation"}
        )
        _check(resp)
        rows: list[dict[str, Any]] = resp.json()
        return rows

    async def upsert(
        self, table: str, row: dict[str, Any], on_conflict: str
    ) -> list[dict[str, Any]]:
        """INSERT … ON CONFLICT (on_conflict) DO UPDATE de las columnas enviadas."""
        resp = await self._client.post(
            f"/{table}",
            params={"on_conflict": on_conflict},
            json=row,
            headers={"Prefer": "return=representation,resolution=merge-duplicates"},
        )
        _check(resp)
        rows: list[dict[str, Any]] = resp.json()
        return rows

    async def update(
        self, table: str, params: dict[str, str], values: dict[str, Any]
    ) -> list[dict[str, Any]]:
        resp = await self._client.patch(
            f"/{table}", params=params, json=values, headers={"Prefer": "return=representation"}
        )
        _check(resp)
        rows: list[dict[str, Any]] = resp.json()
        return rows

    async def delete(self, table: str, params: dict[str, str]) -> list[dict[str, Any]]:
        resp = await self._client.delete(
            f"/{table}", params=params, headers={"Prefer": "return=representation"}
        )
        _check(resp)
        rows: list[dict[str, Any]] = resp.json()
        return rows

    async def rpc(self, fn: str, args: dict[str, Any]) -> Any:
        resp = await self._client.post(f"/rpc/{fn}", json=args)
        _check(resp)
        return resp.json()

    async def aclose(self) -> None:
        await self._client.aclose()
