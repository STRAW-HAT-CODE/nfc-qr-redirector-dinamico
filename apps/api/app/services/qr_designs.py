"""Diseño de QR por enlace (DQR-T032): BD con el JWT del usuario, logos en Storage y descargas.

El logo solo se descarga desde `qr_designs.logo_path` (bucket `logos` fijo), nunca desde un
parámetro de la petición (security T031-H3). Todo con el JWT del usuario (RLS/policies).
"""

from __future__ import annotations

import asyncio
import io
import re
from dataclasses import replace
from typing import Any
from uuid import UUID, uuid4

import httpx
from PIL import Image

from app.core.config import Settings
from app.db import PostgrestError, UserDB
from app.errors import ApiError
from app.schemas.qr import DesignIn, DesignOut
from app.services.limits import plan_limit_error
from app.services.print_templates import GOOGLE_REVIEW_TEXT, render_template
from app.services.qr_render import (
    LOGO_PRESETS,
    MAX_LOGO_BYTES,
    QrDesign,
    QrRenderError,
    _load_logo,
    _norm_hex,
    check_design,
    preset_logo,
    qr_payload,
    render_pdf,
    render_png,
    render_svg,
)

LINKS = "dynamic_links"
DESIGNS = "qr_designs"
BUCKET = "logos"
LOGO_MAX_SIDE = 1024  # el logo ocupa ≤ 20 % del QR; más resolución no aporta
_LOGO_PATH_RE = re.compile(r"^[0-9a-f-]{36}/[A-Za-z0-9_-][A-Za-z0-9._-]{0,127}\.png$")

# Diseño de un enlace sin fila en qr_designs (DQR-T064): logo de Google, puntos, ojos cuadrados
# y fondo transparente. Solo afecta a enlaces sin diseño guardado.
DEFAULT_ROW: dict[str, Any] = {
    "fg": "#000000",
    "bg": "#ffffff",
    "ecc_level": "H",
    "frame": "none",
    "logo_path": None,
    "style": {"margin": 4, "logo_preset": "google", "module_style": "dots", "bg_transparent": True},
}

MEDIA = {
    "png": "image/png",
    "svg": "image/svg+xml",
    "pdf": "application/pdf",
}


def _map_db_error(exc: PostgrestError) -> ApiError:
    if (limit := plan_limit_error(exc)) is not None:
        return limit
    if exc.code == "42501":
        return ApiError(403, "insufficient_role", "No tienes permiso para esta operación")
    if exc.code in ("23514", "23503"):
        return ApiError(422, "design_invalid", "Diseño no válido")
    return ApiError(502, "upstream_error", "Error al consultar la base de datos")


def _row_preset(row: dict[str, Any] | None) -> str | None:
    """`style.logo_preset` si está en la lista blanca; cualquier otro valor se ignora."""
    style = row.get("style") if row else None
    value = style.get("logo_preset") if isinstance(style, dict) else None
    return value if isinstance(value, str) and value in LOGO_PRESETS else None


def _default_title(link: dict[str, Any], slug: str) -> str:
    """Nombre del enlace apto para la plantilla (≤ 80, sin caracteres de control)."""
    name = "".join(c if c.isprintable() else " " for c in str(link.get("name") or ""))
    return " ".join(name.split())[:80].strip() or slug


def reencode_logo(data: bytes) -> bytes:
    """Valida (formato, bytes, píxeles) y re-encodea a PNG RGBA limpio (sin metadatos/payloads)."""
    try:
        im = _load_logo(data)
    except QrRenderError as exc:
        raise ApiError(422, "logo_invalid", str(exc)) from None
    im.thumbnail((LOGO_MAX_SIDE, LOGO_MAX_SIDE), Image.Resampling.LANCZOS)
    clean = Image.new("RGBA", im.size)
    clean.paste(im)  # copia solo los píxeles
    out = io.BytesIO()
    clean.save(out, format="PNG", optimize=True)
    png = out.getvalue()
    if len(png) > MAX_LOGO_BYTES:
        raise ApiError(413, "logo_too_large", "El logo supera 1 MB tras normalizarlo")
    return png


class QrDesignService:
    def __init__(self, db: UserDB, settings: Settings, org_id: UUID, user_token: str) -> None:
        self._db = db
        self._settings = settings
        self._org_id = org_id
        self._token = user_token

    # ------------------------------------------------------------------ BD

    async def _run(self, op: Any) -> Any:
        try:
            return await op
        except PostgrestError as exc:
            raise _map_db_error(exc) from exc
        except httpx.HTTPError:
            raise ApiError(502, "upstream_error", "No se pudo consultar la base de datos") from None

    async def _link(self, link_id: UUID) -> dict[str, Any]:
        rows = await self._run(
            self._db.select(
                LINKS,
                {"select": "id,slug,name", "id": f"eq.{link_id}", "org_id": f"eq.{self._org_id}"},
            )
        )
        if not rows:
            raise ApiError(404, "link_not_found", "Enlace no encontrado")
        return dict(rows[0])

    async def _slug(self, link_id: UUID) -> str:
        return str((await self._link(link_id))["slug"])

    async def _has_nfc(self, link_id: UUID) -> bool:
        rows = await self._run(
            self._db.select(
                "nfc_tags",
                {
                    "select": "id",
                    "link_id": f"eq.{link_id}",
                    "org_id": f"eq.{self._org_id}",
                    "limit": "1",
                },
            )
        )
        return bool(rows)

    async def _row(self, link_id: UUID) -> dict[str, Any] | None:
        rows = await self._run(
            self._db.select(
                DESIGNS,
                {"select": "*", "link_id": f"eq.{link_id}", "org_id": f"eq.{self._org_id}"},
            )
        )
        return rows[0] if rows else None

    # ------------------------------------------------------------------ Storage

    def _storage(self) -> httpx.AsyncClient:
        return httpx.AsyncClient(
            base_url=f"{self._settings.supabase_url.rstrip('/')}/storage/v1",
            headers={
                "apikey": self._settings.supabase_anon_key,
                "Authorization": f"Bearer {self._token}",
            },
            timeout=15.0,
        )

    def _own_path(self, path: str) -> bool:
        return bool(_LOGO_PATH_RE.match(path)) and path.startswith(f"{self._org_id}/")

    async def _put_logo(self, path: str, png: bytes) -> None:
        try:
            async with self._storage() as c:
                resp = await c.post(
                    f"/object/{BUCKET}/{path}",
                    content=png,
                    headers={"Content-Type": "image/png", "x-upsert": "false"},
                )
        except httpx.HTTPError:
            raise ApiError(502, "upstream_error", "No se pudo subir el logo") from None
        if resp.status_code in (400, 401, 403):
            raise ApiError(403, "insufficient_role", "No tienes permiso para subir el logo")
        if resp.status_code >= 400:
            raise ApiError(502, "upstream_error", "No se pudo subir el logo")

    async def _delete_logo(self, path: str | None) -> None:
        """Borrado best-effort; un fallo deja un huérfano (limpieza en T052)."""
        if not path or not self._own_path(path):
            return
        try:
            async with self._storage() as c:
                await c.delete(f"/object/{BUCKET}/{path}")
        except httpx.HTTPError:
            return

    async def _fetch_logo(self, path: str) -> bytes:
        if not self._own_path(path):
            raise ApiError(500, "design_corrupt", "Ruta de logo inválida")
        try:
            async with self._storage() as c:
                resp = await c.get(f"/object/authenticated/{BUCKET}/{path}")
        except httpx.HTTPError:
            raise ApiError(502, "upstream_error", "No se pudo leer el logo") from None
        if resp.status_code >= 400:
            raise ApiError(502, "upstream_error", "No se pudo leer el logo")
        if len(resp.content) > MAX_LOGO_BYTES:
            raise ApiError(502, "upstream_error", "Logo almacenado demasiado grande")
        return resp.content

    # ------------------------------------------------------------------ diseño

    @staticmethod
    def _to_design(row: dict[str, Any] | None, logo: bytes | None = None) -> QrDesign:
        """Fila → QrDesign. `style` pasa por lista blanca; valores inválidos → defaults."""
        if row is None:
            row = DEFAULT_ROW
        raw_style = row.get("style")
        style: dict[str, Any] = raw_style if isinstance(raw_style, dict) else {}
        base: dict[str, Any] = {
            "fg": row["fg"],
            "bg": row["bg"],
            "ecc": row["ecc_level"],
            "frame": row["frame"],
        }
        extra: dict[str, Any] = {}
        for key in ("module_style", "margin", "frame_text"):
            if key in style:
                try:
                    QrDesign(**{key: style[key]})
                except (QrRenderError, TypeError):
                    continue
                extra[key] = style[key]
        if style.get("bg_transparent") is True:
            extra["bg_transparent"] = True
        preset = _row_preset(row)
        if preset:  # el preset gana sobre logo_path; el logo sale del asset incluido
            logo = preset_logo(preset)
        return QrDesign(**base, **extra, logo=logo)

    def _out(self, link_id: UUID, row: dict[str, Any] | None) -> DesignOut:
        is_default = row is None
        row = DEFAULT_ROW if row is None else row
        d = self._to_design(row)
        has_logo = bool(row.get("logo_path"))
        preset = _row_preset(row)
        warnings = check_design(d)
        return DesignOut(
            link_id=str(link_id),
            fg=d.fg,
            bg=d.bg,
            ecc_level="H" if has_logo or preset else d.ecc,
            frame=d.frame,
            module_style=d.module_style,
            margin=d.margin,
            frame_text=d.frame_text,
            has_logo=has_logo,
            logo_preset=preset,
            style=(row.get("style") if isinstance(row.get("style"), dict) else {}),
            is_default=is_default,
            updated_at=row.get("updated_at"),
            warnings=warnings,
        )

    async def get_design(self, link_id: UUID) -> DesignOut:
        await self._slug(link_id)
        return self._out(link_id, await self._row(link_id))

    async def put_design(self, link_id: UUID, body: DesignIn) -> DesignOut:
        await self._slug(link_id)
        try:
            QrDesign(
                fg=body.fg,
                bg=body.bg,
                ecc=body.ecc_level,
                frame=body.frame,
                module_style=body.module_style,
                margin=body.margin,
                frame_text=body.frame_text or None,
                bg_transparent=body.bg_transparent,
            )
        except QrRenderError as exc:
            raise ApiError(422, "design_invalid", str(exc)) from None
        current = await self._row(link_id)
        has_logo = bool(current and current.get("logo_path"))
        style: dict[str, Any] = {"module_style": body.module_style, "margin": body.margin}
        if body.frame_text:
            style["frame_text"] = body.frame_text
        if body.logo_preset:
            style["logo_preset"] = body.logo_preset
        if body.bg_transparent:
            style["bg_transparent"] = True
        row = {
            "link_id": str(link_id),
            "org_id": str(self._org_id),
            "fg": _norm_hex(body.fg, "fg"),
            "bg": _norm_hex(body.bg, "bg"),
            "frame": body.frame,
            # con logo o preset, H (CHECK en BD)
            "ecc_level": "H" if has_logo or body.logo_preset else body.ecc_level,
            "style": style,
        }
        rows = await self._run(self._db.upsert(DESIGNS, row, "link_id"))
        return self._out(link_id, rows[0])

    async def set_logo(self, link_id: UUID, data: bytes) -> DesignOut:
        await self._slug(link_id)
        png = await asyncio.to_thread(reencode_logo, data)
        current = await self._row(link_id)
        old = str(current["logo_path"]) if current and current.get("logo_path") else None
        path = f"{self._org_id}/{link_id}-{uuid4()}.png"
        await self._put_logo(path, png)
        row: dict[str, Any] = {
            "link_id": str(link_id),
            "org_id": str(self._org_id),
            "logo_path": path,
            "ecc_level": "H",
        }
        try:
            rows = await self._run(self._db.upsert(DESIGNS, row, "link_id"))
        except ApiError:
            await self._delete_logo(path)
            raise
        await self._delete_logo(old)
        return self._out(link_id, rows[0])

    async def delete_logo(self, link_id: UUID) -> DesignOut:
        await self._slug(link_id)
        current = await self._row(link_id)
        if not current or not current.get("logo_path"):
            return self._out(link_id, current)
        old = str(current["logo_path"])
        rows = await self._run(
            self._db.update(
                DESIGNS,
                {"link_id": f"eq.{link_id}", "org_id": f"eq.{self._org_id}"},
                {"logo_path": None},
            )
        )
        await self._delete_logo(old)
        return self._out(link_id, rows[0] if rows else current)

    # ------------------------------------------------------------------ descargas

    async def render(
        self,
        link_id: UUID,
        fmt: str,
        size: int,
        template: str = "none",
        title: str | None = None,
    ) -> tuple[bytes, str, list[str]]:
        """(contenido, slug, avisos). Con `template` ≠ none: pieza imprimible (DQR-T033)."""
        link = await self._link(link_id)
        slug = str(link["slug"])
        nfc = await self._has_nfc(link_id) if template != "none" else False
        row = await self._row(link_id)
        logo = None
        preset = "google" if template == "google_review" else _row_preset(row or DEFAULT_ROW)
        if preset is None and row and row.get("logo_path"):  # el preset evita tocar Storage
            logo = await self._fetch_logo(str(row["logo_path"]))
        try:
            design = self._to_design(row, logo)
            if template != "none":  # las piezas imprimibles llevan su propio fondo
                design = replace(design, bg_transparent=False)
            if template == "google_review":  # la plantilla siempre lleva la G, con ECC H
                design = replace(design, logo=preset_logo("google"))
            payload = qr_payload(self._settings.public_redirect_base_url, slug, "q")
        except QrRenderError:
            raise ApiError(
                500, "config_error", "Diseño o PUBLIC_REDIRECT_BASE_URL no válidos"
            ) from None
        warnings = check_design(design)

        def work() -> bytes:
            if template != "none":
                return render_template(
                    template,
                    fmt,  # type: ignore[arg-type]
                    payload,
                    design,
                    (title or _default_title(link, slug))
                    if template != "google_review"
                    else (title or GOOGLE_REVIEW_TEXT),
                    nfc,
                    _default_title(link, slug) if template == "google_review" else None,
                )
            if fmt == "png":
                return render_png(payload, design, size)
            if fmt == "pdf":
                return render_pdf(payload, design, size)
            return render_svg(payload, design).encode("utf-8")

        try:
            return await asyncio.to_thread(work), slug, warnings
        except QrRenderError as exc:
            raise ApiError(422, "design_invalid", str(exc)) from None
