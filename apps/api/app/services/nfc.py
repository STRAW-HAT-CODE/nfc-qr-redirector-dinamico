"""Lógica de etiquetas NFC: acceso a BD con el JWT del usuario, URL NDEF y tamaño del registro."""

from typing import Any
from uuid import UUID

import httpx

from app.core.config import Settings
from app.db import PostgrestError, UserDB
from app.errors import ApiError
from app.schemas.nfc import NfcTagCreate, NfcTagList, NfcTagOut, NfcTagUpdate
from app.services.qr_render import QrRenderError, qr_payload

LINKS = "dynamic_links"
TAGS = "nfc_tags"

# NTAG213: 144 bytes de memoria de usuario. Se reservan 3 bytes del TLV (0x03, longitud, 0xFE)
# y 4 de margen para la cabecera de capacidad → 137 bytes útiles para el registro NDEF.
NTAG213_USABLE_BYTES = 137

_URI_PREFIXES = (("https://", 0x04), ("http://", 0x03))


def ndef_record_size(url: str) -> int:
    """Largo en bytes del registro NDEF URI corto (SR) con prefijo abreviado.

    Cabecera (0xD1) + longitud del tipo + longitud del payload + tipo "U" = 4 bytes;
    payload = 1 byte de código de prefijo + resto de la URL en UTF-8.
    """
    code = 0x00
    rest = url
    for prefix, c in _URI_PREFIXES:
        if url.lower().startswith(prefix):
            code, rest = c, url[len(prefix) :]
            break
    del code  # el código ocupa 1 byte sea cual sea
    return 4 + 1 + len(rest.encode("utf-8"))


def map_db_error(exc: PostgrestError) -> ApiError:
    if exc.code == "42501":
        return ApiError(403, "insufficient_role", "No tienes permiso para esta operación")
    if exc.code == "23505":
        return ApiError(409, "nfc_uid_conflict", "Ese UID ya está registrado en la organización")
    if exc.code == "23514":
        msg = exc.message
        if "uid_check" in msg:
            return ApiError(
                422, "nfc_uid_invalid", "UID inválido: hex de 4, 7 o 10 bytes (p. ej. 04:A2:5B:1C)"
            )
        return ApiError(422, "nfc_tag_invalid", "Etiqueta o ubicación no válida")
    return ApiError(502, "upstream_error", "Error al consultar la base de datos")


def _link_not_found() -> ApiError:
    return ApiError(404, "link_not_found", "Enlace no encontrado")


def _tag_not_found() -> ApiError:
    return ApiError(404, "nfc_tag_not_found", "Etiqueta NFC no encontrada")


class NfcService:
    def __init__(self, db: UserDB, settings: Settings, org_id: UUID) -> None:
        self._db = db
        self._settings = settings
        self._org_id = org_id

    async def _run(self, op: Any) -> Any:
        try:
            return await op
        except PostgrestError as exc:
            raise map_db_error(exc) from exc
        except httpx.HTTPError:
            raise ApiError(502, "upstream_error", "No se pudo consultar la base de datos") from None

    async def _slug(self, link_id: UUID) -> str:
        rows = await self._run(
            self._db.select(
                LINKS,
                {"select": "id,slug", "id": f"eq.{link_id}", "org_id": f"eq.{self._org_id}"},
            )
        )
        if not rows:
            raise _link_not_found()  # igual si existe en otra org: no se revela
        return str(rows[0]["slug"])

    def _out(self, row: dict[str, Any], slug: str) -> NfcTagOut:
        try:
            url = qr_payload(self._settings.public_redirect_base_url, slug, "n", str(row["id"]))
        except QrRenderError:
            raise ApiError(500, "config_error", "PUBLIC_REDIRECT_BASE_URL no es válida") from None
        size = ndef_record_size(url)
        fits = size <= NTAG213_USABLE_BYTES
        warning = (
            None
            if fits
            else f"La URL NDEF ocupa {size} bytes y supera los {NTAG213_USABLE_BYTES} útiles "
            "de un NTAG213; usa un NTAG215/216 o un dominio más corto"
        )
        return NfcTagOut(**row, ndef_url=url, ndef_bytes=size, ndef_fits=fits, ndef_warning=warning)

    def _scope(self, link_id: UUID, tag_id: UUID | None = None) -> dict[str, str]:
        params = {"link_id": f"eq.{link_id}", "org_id": f"eq.{self._org_id}"}
        if tag_id is not None:
            params["id"] = f"eq.{tag_id}"
        return params

    async def list_tags(self, link_id: UUID) -> NfcTagList:
        slug = await self._slug(link_id)
        rows = await self._run(
            self._db.select(
                TAGS,
                {"select": "*", **self._scope(link_id), "order": "created_at.desc,id.desc"},
            )
        )
        return NfcTagList(items=[self._out(r, slug) for r in rows])

    async def create(self, link_id: UUID, body: NfcTagCreate) -> NfcTagOut:
        slug = await self._slug(link_id)
        row: dict[str, Any] = {
            "link_id": str(link_id),
            "org_id": str(self._org_id),
            "label": body.label,
            "location": body.location,
            "uid": body.uid,
        }
        rows = await self._run(self._db.insert(TAGS, row))
        return self._out(rows[0], slug)

    async def update(self, link_id: UUID, tag_id: UUID, body: NfcTagUpdate) -> NfcTagOut:
        slug = await self._slug(link_id)
        values = {
            f: getattr(body, f)
            for f in body.model_fields_set
            if not (f == "label" and body.label is None)
        }
        if values:
            rows = await self._run(self._db.update(TAGS, self._scope(link_id, tag_id), values))
        else:
            rows = await self._run(
                self._db.select(TAGS, {"select": "*", **self._scope(link_id, tag_id)})
            )
        if not rows:
            raise _tag_not_found()
        return self._out(rows[0], slug)

    async def delete(self, link_id: UUID, tag_id: UUID) -> NfcTagOut:
        slug = await self._slug(link_id)
        rows = await self._run(self._db.delete(TAGS, self._scope(link_id, tag_id)))
        if not rows:
            raise _tag_not_found()
        return self._out(rows[0], slug)
