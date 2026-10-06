"""Registro asíncrono del escaneo (DQR-T023, docs/06-seguridad.md).

Se ejecuta en una BackgroundTask del redirector y NUNCA rompe la redirección:
timeout de 2 s y cualquier excepción se loguea sin datos sensibles (ni IP ni sal).

Privacidad:
- Nunca se guarda la IP: `ip_hash = HMAC-SHA256(IP_HASH_SALT, "YYYY-MM-DD|IP")` (hex, 64).
  La fecha UTC entra en el mensaje, así que el hash rota cada día y los conteos
  únicos son por día.
- `x-forwarded-for` solo se usa con `TRUSTED_PROXY_HOPS` > 0 (por defecto 0): se toma la
  entrada que añadió el proxy confiable más externo, contando desde la derecha.
  En Vercel, que sobrescribe x-forwarded-for con la IP real del cliente, usar 1.
- Referer: solo el origen (scheme://host[:port]).
- device/os/browser quedan en null: el enriquecimiento es de T040.
"""

import asyncio
import hashlib
import hmac
import ipaddress
import logging
import re
from datetime import UTC, datetime
from typing import Any
from urllib.parse import urlsplit
from uuid import UUID

from fastapi import Request

from app.core.config import get_settings
from app.service_db import ServiceDB

logger = logging.getLogger(__name__)

_TIMEOUT_S = 2.0
_COUNTRY_RE = re.compile(r"^[A-Z]{2}$")
_MAX_REFERER = 512
# Heurística mínima; T040 (analytics) la reemplaza con la detección real de bots.
_BOT_MARKERS = (
    "curl", "wget", "bot", "spider", "crawler", "facebookexternalhit", "preview",
)  # fmt: skip
_warned_no_salt = False


def is_bot(user_agent: str | None) -> bool:
    ua = (user_agent or "").strip().lower()
    return not ua or any(m in ua for m in _BOT_MARKERS)


def parse_tag_id(tag: str | None, channel: str) -> str | None:
    """Solo UUID válido y canal nfc; T034 añade la FK."""
    if channel != "nfc" or not tag:
        return None
    try:
        return str(UUID(tag))
    except ValueError:
        return None


def parse_country(value: str | None) -> str | None:
    v = (value or "").strip().upper()
    return v if _COUNTRY_RE.fullmatch(v) else None


def referer_origin(value: str | None) -> str | None:
    if not value:
        return None
    try:
        parts = urlsplit(value.strip())
        host, port = parts.hostname, parts.port
    except ValueError:
        return None
    if parts.scheme not in {"http", "https"} or not host:
        return None
    if ":" in host:  # IPv6
        host = f"[{host}]"
    origin = f"{parts.scheme}://{host}" + (f":{port}" if port else "")
    return origin if len(origin) <= _MAX_REFERER else None


def _norm_ip(raw: str | None) -> str | None:
    """IP canónica (IPv6 comprimida, IPv4 mapeada → IPv4); basura o con puerto → None."""
    if not raw:
        return None
    try:
        ip = ipaddress.ip_address(raw.strip())
    except ValueError:
        return None
    if isinstance(ip, ipaddress.IPv6Address) and ip.ipv4_mapped:
        ip = ip.ipv4_mapped
    return ip.compressed


def client_ip(request: Request, trusted_hops: int) -> str | None:
    direct = _norm_ip(request.client.host if request.client else None)
    if trusted_hops <= 0:
        return direct
    chain = [p.strip() for p in request.headers.get("x-forwarded-for", "").split(",") if p.strip()]
    if len(chain) >= trusted_hops:
        return _norm_ip(chain[-trusted_hops])
    return direct


def hash_ip(ip: str | None, salt: str, now: datetime | None = None) -> str | None:
    """HMAC-SHA256 con la fecha UTC en el mensaje (rota a diario)."""
    global _warned_no_salt
    if not salt:
        if not _warned_no_salt:
            _warned_no_salt = True
            logger.warning("IP_HASH_SALT no configurada; ip_hash se guarda como null")
        return None
    if not ip:
        return None
    day = (now or datetime.now(UTC)).astimezone(UTC).strftime("%Y-%m-%d")
    return hmac.new(salt.encode(), f"{day}|{ip}".encode(), hashlib.sha256).hexdigest()


def build_payload(
    link: dict[str, Any], channel: str, tag: str | None, request: Request
) -> dict[str, Any]:
    settings = get_settings()
    ip = client_ip(request, settings.trusted_proxy_hops)
    return {
        "p_link_id": link["id"],
        "p_org_id": link["org_id"],
        "p_channel": channel,
        "p_tag_id": parse_tag_id(tag, channel),
        # Sin proxy confiable la cabecera la controla el cliente: se ignora.
        "p_country": (
            parse_country(request.headers.get("x-vercel-ip-country"))
            if settings.trusted_proxy_hops >= 1
            else None
        ),
        "p_device": None,
        "p_os": None,
        "p_browser": None,
        "p_referer": referer_origin(request.headers.get("referer")),
        "p_ip_hash": hash_ip(ip, settings.ip_hash_salt),
        "p_is_bot": is_bot(request.headers.get("user-agent")),
    }


async def log_scan(link: dict[str, Any], channel: str, tag: str | None, request: Request) -> None:
    """Registra el escaneo; nunca lanza. Org suspendida → no registra."""
    try:
        if link.get("org_status") != "active":
            return
        payload = build_payload(link, channel, tag, request)
        async with asyncio.timeout(_TIMEOUT_S):
            await ServiceDB(request.app.state.service_client).rpc("record_scan", payload)
    except Exception as exc:
        # Sin payload, IP ni sal: solo el tipo de error.
        logger.warning("record_scan falló (%s)", type(exc).__name__)
