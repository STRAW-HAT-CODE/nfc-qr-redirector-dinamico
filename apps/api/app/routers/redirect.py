"""Redirector público GET|HEAD /r/{slug} (ADR-0003, ADR-0004).

- 302 + `Cache-Control: no-store`, nunca 301, sin cookies.
- Solo redirige a URLs guardadas en BD; la query (`c`, `t`) no afecta el destino.
- El registro del escaneo (T023) va en una BackgroundTask que nunca rompe la respuesta.
"""

import asyncio
import logging
from datetime import UTC, datetime
from enum import StrEnum
from typing import Any
from urllib.parse import quote, urlsplit

from fastapi import APIRouter, BackgroundTasks, Request, Response

from app.service_db import ServiceDB
from app.services.scan_logger import log_scan
from app.services.slug import is_valid_slug

logger = logging.getLogger(__name__)
router = APIRouter()

_NO_STORE = {"Cache-Control": "no-store"}
_MAX_TAG_LEN = 64


class Channel(StrEnum):
    QR = "qr"
    NFC = "nfc"
    DIRECT = "direct"


def parse_channel(c: str | None) -> Channel:
    return {"q": Channel.QR, "n": Channel.NFC}.get(c or "", Channel.DIRECT)


def parse_tag(t: str | None) -> str | None:
    """Etiqueta NFC: ASCII imprimible corto; si no es válida se ignora."""
    if t and len(t) <= _MAX_TAG_LEN and t.isascii() and t.isprintable():
        return t
    return None


def _page(title: str, text: str, status: int, head: bool) -> Response:
    html = (
        '<!doctype html><html lang="es"><head><meta charset="utf-8">'
        '<meta name="viewport" content="width=device-width,initial-scale=1">'
        '<meta name="robots" content="noindex">'
        f"<title>{title}</title></head>"
        '<body style="font-family:system-ui,sans-serif;text-align:center;padding:4rem 1rem">'
        f"<h1>{title}</h1><p>{text}</p></body></html>"
    )
    return Response(
        content=b"" if head else html,
        status_code=status,
        media_type="text/html",
        headers=_NO_STORE,
    )


def _unavailable(head: bool, status: int = 200) -> Response:
    return _page("Enlace no disponible", "Este enlace no está disponible por ahora.", status, head)


def _not_found(head: bool) -> Response:
    return _page("Enlace no encontrado", "No encontramos el enlace que buscas.", 404, head)


_URL_SAFE = "!#$%&'()*+,/:;=?@[]~"
_RPC_TIMEOUT_S = 1.5


def _redirect(url: str) -> Response:
    """302 al destino guardado, percent-encoded (UTF-8) y solo http(s)."""
    if not isinstance(url, str) or urlsplit(url).scheme.lower() not in {"http", "https"}:
        raise ValueError("destino no http(s)")
    return Response(status_code=302, headers={**_NO_STORE, "Location": quote(url, safe=_URL_SAFE)})


def _parse_ts(value: str | None) -> datetime | None:
    return datetime.fromisoformat(value) if value else None


def _is_live(link: dict[str, Any], now: datetime) -> bool:
    """Activo y dentro de vigencia."""
    if link["status"] != "active":
        return False
    starts, expires = _parse_ts(link.get("starts_at")), _parse_ts(link.get("expires_at"))
    return not ((starts and starts > now) or (expires and expires <= now))


async def on_scan(
    link: dict[str, Any], channel: Channel, tag: str | None, request: Request
) -> None:
    """Hook del registro de escaneo (DQR-T023): delega en el scan_logger."""
    await log_scan(link, channel.value, tag, request)


async def _safe_on_scan(
    link: dict[str, Any], channel: Channel, tag: str | None, request: Request
) -> None:
    try:
        await on_scan(link, channel, tag, request)
    except Exception:
        logger.exception("on_scan falló; la redirección no se ve afectada")


def get_service_db(request: Request) -> ServiceDB:
    return ServiceDB(request.app.state.service_client)


@router.api_route("/r/{slug}", methods=["GET", "HEAD"], include_in_schema=False)
@router.api_route("/r/{slug}/", methods=["GET", "HEAD"], include_in_schema=False)
async def redirect(
    slug: str,
    request: Request,
    background: BackgroundTasks,
    c: str | None = None,
    t: str | None = None,
) -> Response:
    head = request.method == "HEAD"
    if not is_valid_slug(slug):
        return _not_found(head)

    try:
        async with asyncio.timeout(_RPC_TIMEOUT_S):
            rows = await get_service_db(request).rpc("resolve_link", {"p_slug": slug})
    except Exception:
        logger.warning("resolve_link falló", exc_info=True)
        return _unavailable(head, status=503)

    if not isinstance(rows, list):
        logger.warning("resolve_link devolvió un tipo inesperado")
        return _unavailable(head, status=503)
    if not rows:
        return _not_found(head)

    try:
        link = rows[0]
        if link["org_status"] != "active":
            response = _unavailable(head)
        elif _is_live(link, datetime.now(UTC)):
            response = _redirect(link["destination_url"])
        elif link.get("fallback_url"):
            response = _redirect(link["fallback_url"])
        else:
            response = _unavailable(head)
    except Exception:  # cualquier fila malformada → 503 genérico
        logger.warning("fila de resolve_link inválida", exc_info=True)
        return _unavailable(head, status=503)

    if not head:
        background.add_task(_safe_on_scan, link, parse_channel(c), parse_tag(t), request)
    return response
