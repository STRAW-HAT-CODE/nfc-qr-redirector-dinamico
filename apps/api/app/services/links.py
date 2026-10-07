"""Lógica de enlaces: validación de URLs, acceso a BD con el JWT del usuario y mapeo de errores."""

import logging
from typing import Any
from uuid import UUID

import httpx

from app.core.config import Settings
from app.db import PostgrestError, UserDB
from app.errors import ApiError
from app.schemas.links import (
    HistoryOut,
    HistoryPage,
    LinkCreate,
    LinkOut,
    LinkPage,
    LinkStatus,
    LinkUpdate,
)
from app.services.limits import plan_limit_error
from app.services.url_policy import UrlPolicyError, validate_destination

log = logging.getLogger(__name__)

LINKS = "dynamic_links"
DESIGNS = "qr_designs"
LOGO_BUCKET = "logos"
HISTORY = "link_destination_history"


def map_db_error(exc: PostgrestError) -> ApiError:
    """SQLSTATE de la BD → error de API (docs/04-api.md)."""
    if (limit := plan_limit_error(exc)) is not None:
        return limit
    if exc.code == "42501":
        return ApiError(403, "insufficient_role", "No tienes permiso para esta operación")
    if exc.code == "23514":
        if exc.hint == "url_blocked_domain":
            return ApiError(422, "url_blocked_domain", "El dominio de destino no está permitido")
        if "window_check" in exc.message:
            return ApiError(422, "invalid_window", "starts_at debe ser anterior a expires_at")
        return ApiError(422, "url_invalid", "La URL no es válida")
    return ApiError(502, "upstream_error", "Error al consultar la base de datos")


def _not_found() -> ApiError:
    # Mismo error exista o no en otra org: no se revela.
    return ApiError(404, "link_not_found", "Enlace no encontrado")


class LinksService:
    def __init__(self, db: UserDB, settings: Settings, org_id: UUID, token: str = "") -> None:
        self._db = db
        self._token = token
        self._settings = settings
        self._org_id = org_id

    # -- helpers ------------------------------------------------------------
    def short_url(self, slug: str) -> str:
        return f"{self._settings.public_redirect_base_url.rstrip('/')}/r/{slug}"

    def _out(self, row: dict[str, Any]) -> LinkOut:
        return LinkOut(**row, short_url=self.short_url(row["slug"]))

    def _url(self, url: str) -> str:
        try:
            return validate_destination(
                url, redirector_base_url=self._settings.public_redirect_base_url
            )
        except UrlPolicyError as exc:
            raise ApiError(422, exc.code, exc.message) from exc

    async def _run(self, op: Any) -> Any:
        try:
            return await op
        except PostgrestError as exc:
            raise map_db_error(exc) from exc
        except httpx.HTTPError:
            raise ApiError(502, "upstream_error", "No se pudo consultar la base de datos") from None

    def _scope(self, link_id: UUID) -> dict[str, str]:
        return {"id": f"eq.{link_id}", "org_id": f"eq.{self._org_id}"}

    async def _fetch(self, link_id: UUID) -> dict[str, Any]:
        rows = await self._run(self._db.select(LINKS, {"select": "*", **self._scope(link_id)}))
        if not rows:
            raise _not_found()
        row: dict[str, Any] = rows[0]
        return row

    async def _patch(self, link_id: UUID, values: dict[str, Any]) -> LinkOut:
        if not values:
            return self._out(await self._fetch(link_id))
        rows = await self._run(self._db.update(LINKS, self._scope(link_id), values))
        if rows:
            return self._out(rows[0])
        # Sin filas: no existe, o la RLS lo impide (un archivado solo lo toca admin+).
        await self._fetch(link_id)  # 404 si no existe / otra org
        raise ApiError(403, "insufficient_role", "Un enlace archivado solo lo modifica un admin")

    # -- casos de uso -------------------------------------------------------
    async def list_links(
        self, *, q: str | None, status: LinkStatus | None, limit: int, offset: int
    ) -> LinkPage:
        params = {
            "select": "*",
            "org_id": f"eq.{self._org_id}",
            "order": "created_at.desc,id.desc",
            "limit": str(limit + 1),
            "offset": str(offset),
        }
        if status:
            params["status"] = f"eq.{status.value}"
        if q and q.strip():
            term = q.strip().replace("\\", "\\\\").replace("%", "\\%").replace("_", "\\_")
            params["name"] = f"ilike.*{term.replace('*', '')}*"
        rows = await self._run(self._db.select(LINKS, params))
        return LinkPage(
            items=[self._out(r) for r in rows[:limit]],
            limit=limit,
            offset=offset,
            has_more=len(rows) > limit,
        )

    async def create(self, body: LinkCreate) -> LinkOut:
        row: dict[str, Any] = {
            "org_id": str(self._org_id),
            "name": body.name,
            "destination_url": self._url(body.destination_url),
            "status": body.status.value,
        }
        if body.fallback_url is not None:
            row["fallback_url"] = self._url(body.fallback_url)
        if body.starts_at:
            row["starts_at"] = body.starts_at.isoformat()
        if body.expires_at:
            row["expires_at"] = body.expires_at.isoformat()
        rows = await self._run(self._db.insert(LINKS, row))
        return self._out(rows[0])

    async def get(self, link_id: UUID) -> LinkOut:
        return self._out(await self._fetch(link_id))

    async def update(self, link_id: UUID, body: LinkUpdate) -> LinkOut:
        values: dict[str, Any] = {}
        for field in body.model_fields_set:
            value = getattr(body, field)
            if field == "name" and value is None:
                continue
            if field == "status":
                if value is None:
                    continue
                value = value.value
            elif field == "fallback_url" and value is not None:
                value = self._url(value)
            elif field in ("starts_at", "expires_at") and value is not None:
                value = value.isoformat()
            values[field] = value
        return await self._patch(link_id, values)

    async def archive(self, link_id: UUID) -> LinkOut:
        return await self._patch(link_id, {"status": LinkStatus.archived.value})

    async def _delete_logo(self, path: str) -> None:
        """Borra el logo del bucket con el JWT del usuario; un fallo se registra y se ignora."""
        try:
            async with httpx.AsyncClient(
                base_url=f"{self._settings.supabase_url.rstrip('/')}/storage/v1",
                headers={
                    "apikey": self._settings.supabase_anon_key,
                    "Authorization": f"Bearer {self._token}",
                },
                timeout=15.0,
            ) as client:
                resp = await client.delete(f"/object/{LOGO_BUCKET}/{path}")
            if resp.status_code >= 400:
                log.warning("No se pudo borrar el logo (HTTP %s)", resp.status_code)
        except httpx.HTTPError:
            log.warning("No se pudo borrar el logo (error de red)")

    async def delete_permanently(self, link_id: UUID) -> None:
        """Borrado definitivo: logo (best-effort) y fila; las FK en cascada borran el resto."""
        await self._fetch(link_id)  # 404 si no existe / otra org
        designs = await self._run(
            self._db.select(
                DESIGNS,
                {
                    "select": "logo_path",
                    "link_id": f"eq.{link_id}",
                    "org_id": f"eq.{self._org_id}",
                },
            )
        )
        logo_path = designs[0].get("logo_path") if designs else None
        if logo_path:
            await self._delete_logo(logo_path)
        deleted = await self._run(self._db.delete(LINKS, self._scope(link_id)))
        if not deleted:
            # La RLS no lo permite (o ya no existe): no se revela más.
            raise ApiError(403, "insufficient_role", "No tienes permiso para esta operación")

    async def set_destination(self, link_id: UUID, url: str) -> LinkOut:
        return await self._patch(link_id, {"destination_url": self._url(url)})

    async def history(self, link_id: UUID, *, limit: int, offset: int) -> HistoryPage:
        await self._fetch(link_id)
        rows = await self._run(
            self._db.select(
                HISTORY,
                {
                    "select": "*",
                    "link_id": f"eq.{link_id}",
                    "org_id": f"eq.{self._org_id}",
                    "order": "changed_at.desc,id.desc",
                    "limit": str(limit + 1),
                    "offset": str(offset),
                },
            )
        )
        return HistoryPage(
            items=[HistoryOut(**r) for r in rows[:limit]],
            limit=limit,
            offset=offset,
            has_more=len(rows) > limit,
        )
