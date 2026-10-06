"""Utilidades de red compartidas: IP del cliente detrás de proxies confiables."""

import ipaddress

from fastapi import Request


def norm_ip(raw: str | None) -> str | None:
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
    direct = norm_ip(request.client.host if request.client else None)
    if trusted_hops <= 0:
        return direct
    chain = [p.strip() for p in request.headers.get("x-forwarded-for", "").split(",") if p.strip()]
    if len(chain) >= trusted_hops:
        return norm_ip(chain[-trusted_hops])
    return direct
