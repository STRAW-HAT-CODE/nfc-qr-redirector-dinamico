"""Política de URLs de destino (docs/06-seguridad.md: destinos maliciosos, SSRF, bucles).

Funciones puras, sin acceso a BD ni red.
"""

import ipaddress
from urllib.parse import SplitResult, urlsplit, urlunsplit

from app.core.config import get_settings

MAX_URL_LENGTH = 2048
ALLOWED_SCHEMES = frozenset({"http", "https"})
DEFAULT_BLOCKED_DOMAINS: frozenset[str] = frozenset()
_PRIVATE_SUFFIXES = (".localhost", ".local", ".internal")

URL_INVALID = "url_invalid"
URL_TOO_LONG = "url_too_long"
URL_SCHEME_NOT_ALLOWED = "url_scheme_not_allowed"
URL_CREDENTIALS_NOT_ALLOWED = "url_credentials_not_allowed"
URL_PRIVATE_HOST = "url_private_host"
URL_BLOCKED_DOMAIN = "url_blocked_domain"
URL_SELF_REDIRECT = "url_self_redirect"


class UrlPolicyError(ValueError):
    """Destino rechazado. `code` es estable y apto para la API."""

    def __init__(self, code: str, message: str) -> None:
        super().__init__(message)
        self.code = code
        self.message = message


def _parse_ipv4_part(part: str) -> int:
    """Un componente estilo inet_aton: decimal, octal (0…) o hex (0x…)."""
    if not part:
        raise ValueError(part)
    lower = part.lower()
    if lower.startswith("0x"):
        return int(lower[2:] or "0", 16)
    if len(part) > 1 and part.startswith("0"):
        return int(part, 8)
    return int(part, 10)


def _parse_legacy_ipv4(host: str) -> ipaddress.IPv4Address:
    """Interpreta formas como 127.1, 2130706433, 0x7f000001 o 0177.0.0.1."""
    parts = host.split(".")
    if len(parts) > 4:
        raise ValueError(host)
    try:
        nums = [_parse_ipv4_part(p) for p in parts]
    except ValueError as exc:
        raise ValueError(host) from exc
    *head, last = nums
    if any(n < 0 or n > 255 for n in head) or last < 0 or last >= 256 ** (4 - len(head)):
        raise ValueError(host)
    value = last
    for i, n in enumerate(head):
        value |= n << (8 * (3 - i))
    return ipaddress.IPv4Address(value)


def _looks_numeric(host: str) -> bool:
    """El último label numérico (decimal o 0x…) hace que los parsers lo traten como IPv4."""
    last = host.rsplit(".", 1)[-1].lower()
    if last.startswith("0x"):
        return all(c in "0123456789abcdef" for c in last[2:])
    return last.isdigit()


def _is_public_ip(ip: ipaddress.IPv4Address | ipaddress.IPv6Address) -> bool:
    if isinstance(ip, ipaddress.IPv6Address):
        if ip.ipv4_mapped is not None:
            return _is_public_ip(ip.ipv4_mapped)
        if ip.sixtofour is not None:
            return _is_public_ip(ip.sixtofour)
    return ip.is_global and not ip.is_multicast


def _matches_domain(host: str, domain: str) -> bool:
    return host == domain or host.endswith("." + domain)


def _normalize_domains(domains: frozenset[str]) -> frozenset[str]:
    return frozenset(d.strip().lower().strip(".") for d in domains if d.strip().strip("."))


def _redirector_host(base_url: str) -> str | None:
    if not base_url:
        return None
    parts = urlsplit(base_url if "//" in base_url else f"//{base_url}")
    try:
        host = parts.hostname
    except ValueError:
        return None
    return host.rstrip(".") if host else None


def _split(url: str) -> SplitResult:
    if any(ord(c) <= 0x20 or ord(c) == 0x7F for c in url):
        raise UrlPolicyError(URL_INVALID, "La URL contiene espacios o caracteres de control.")
    try:
        return urlsplit(url)
    except ValueError as exc:
        raise UrlPolicyError(URL_INVALID, "La URL no es válida.") from exc


def _check_host(host: str) -> str:
    """Devuelve el host normalizado (minúsculas, punycode, IPv6 sin corchetes) o lanza."""
    host = host.rstrip(".").lower()
    if not host:
        raise UrlPolicyError(URL_INVALID, "La URL debe tener un host.")

    private = UrlPolicyError(URL_PRIVATE_HOST, "El host apunta a una red privada o local.")
    if ":" in host:  # IPv6 (urlsplit ya quitó los corchetes)
        if "%" in host:
            raise UrlPolicyError(URL_INVALID, "La URL no es válida.")
        try:
            ip6 = ipaddress.IPv6Address(host)
        except ValueError as exc:
            raise UrlPolicyError(URL_INVALID, "La URL no es válida.") from exc
        if not _is_public_ip(ip6):
            raise private
        return host

    if _looks_numeric(host):
        try:
            ip4 = _parse_legacy_ipv4(host)
        except ValueError as exc:
            raise UrlPolicyError(URL_INVALID, "La URL no es válida.") from exc
        if not _is_public_ip(ip4):
            raise private
        return str(ip4)

    try:
        host = host.encode("idna").decode("ascii")
    except UnicodeError as exc:
        raise UrlPolicyError(URL_INVALID, "El host no es válido.") from exc
    if host == "localhost" or host.endswith(_PRIVATE_SUFFIXES) or "." not in host:
        raise private
    return host


def validate_destination(
    url: str,
    *,
    blocked_domains: frozenset[str] = DEFAULT_BLOCKED_DOMAINS,
    redirector_base_url: str | None = None,
) -> str:
    """Valida y normaliza un destino. Lanza UrlPolicyError si incumple la política.

    `redirector_base_url` por defecto es PUBLIC_REDIRECT_BASE_URL de la configuración.
    """
    url = url.strip() if isinstance(url, str) else ""
    if not url:
        raise UrlPolicyError(URL_INVALID, "La URL está vacía.")
    if len(url) > MAX_URL_LENGTH:
        raise UrlPolicyError(URL_TOO_LONG, f"La URL supera {MAX_URL_LENGTH} caracteres.")

    parts = _split(url)
    scheme = parts.scheme.lower()
    if scheme not in ALLOWED_SCHEMES:
        raise UrlPolicyError(URL_SCHEME_NOT_ALLOWED, "Solo se permiten URLs http o https.")

    if "@" in parts.netloc:
        raise UrlPolicyError(URL_CREDENTIALS_NOT_ALLOWED, "La URL no puede incluir credenciales.")
    try:
        raw_host = parts.hostname
        port = parts.port
    except ValueError as exc:
        raise UrlPolicyError(URL_INVALID, "La URL no es válida.") from exc
    if not raw_host:
        raise UrlPolicyError(URL_INVALID, "La URL debe tener un host.")

    host = _check_host(raw_host)

    if any(_matches_domain(host, d) for d in _normalize_domains(blocked_domains)):
        raise UrlPolicyError(URL_BLOCKED_DOMAIN, "El dominio de destino no está permitido.")

    base = (
        redirector_base_url
        if redirector_base_url is not None
        else get_settings().public_redirect_base_url
    )
    own_host = _redirector_host(base)
    if own_host and _matches_domain(host, own_host.lower()):
        raise UrlPolicyError(URL_SELF_REDIRECT, "El destino apunta al propio redirector.")

    netloc = f"[{host}]" if ":" in host else host
    if port is not None:
        netloc = f"{netloc}:{port}"
    return urlunsplit((scheme, netloc, parts.path, parts.query, parts.fragment))
