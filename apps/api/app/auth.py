"""Verificación del JWT de Supabase (JWKS asimétrico o HS256 como fallback)."""

import time
from dataclasses import dataclass
from typing import Any

import httpx
import jwt
from jwt import PyJWK

from app.core.config import Settings

AUDIENCE = "authenticated"
ASYMMETRIC_ALGS = ["RS256", "ES256", "EdDSA"]
JWKS_TTL_SECONDS = 600.0
JWKS_REFETCH_COOLDOWN = 30.0


class InvalidTokenError(Exception):
    """El token falta, está mal formado, expiró o no se puede verificar."""


@dataclass(frozen=True, slots=True)
class CurrentUser:
    id: str
    email: str | None
    role: str
    raw_token: str


class JWKSCache:
    """Caché de JWKS con TTL; reintenta una vez si aparece un `kid` desconocido."""

    def __init__(self, url: str, ttl: float = JWKS_TTL_SECONDS) -> None:
        self._url = url
        self._ttl = ttl
        self._keys: dict[str, PyJWK] = {}
        self._fetched_at = 0.0

    async def _refresh(self) -> None:
        async with httpx.AsyncClient(timeout=5.0) as client:
            resp = await client.get(self._url)
            resp.raise_for_status()
            data: dict[str, Any] = resp.json()
        self._keys = {k["kid"]: PyJWK.from_dict(k) for k in data.get("keys", []) if "kid" in k}
        self._fetched_at = time.monotonic()

    async def get_key(self, kid: str) -> PyJWK:
        age = time.monotonic() - self._fetched_at
        unknown_kid = kid not in self._keys and age > JWKS_REFETCH_COOLDOWN
        if not self._keys or age > self._ttl or unknown_kid:
            await self._refresh()
        try:
            return self._keys[kid]
        except KeyError:
            raise InvalidTokenError("unknown signing key") from None


_caches: dict[str, JWKSCache] = {}


def _get_cache(url: str) -> JWKSCache:
    if url not in _caches:
        _caches[url] = JWKSCache(url)
    return _caches[url]


def clear_jwks_cache() -> None:
    _caches.clear()


def issuer_for(settings: Settings) -> str:
    return f"{settings.supabase_url.rstrip('/')}/auth/v1"


async def verify_token(token: str, settings: Settings) -> CurrentUser:
    """Valida firma, exp, aud e iss. Lanza InvalidTokenError ante cualquier fallo."""
    try:
        header = jwt.get_unverified_header(token)
        alg = header.get("alg")
        key: Any
        if alg == "HS256":
            if not settings.supabase_jwt_secret:
                raise InvalidTokenError("HS256 not configured")
            key, algs = settings.supabase_jwt_secret, ["HS256"]
        elif alg in ASYMMETRIC_ALGS:
            kid = header.get("kid")
            if not kid:
                raise InvalidTokenError("missing kid")
            jwks_url = f"{issuer_for(settings)}/.well-known/jwks.json"
            key = (await _get_cache(jwks_url).get_key(kid)).key
            algs = [alg]
        else:
            raise InvalidTokenError("unsupported algorithm")
        claims = jwt.decode(
            token,
            key,
            algorithms=algs,
            audience=AUDIENCE,
            issuer=issuer_for(settings),
            options={"require": ["exp", "sub", "aud", "iss"]},
        )
    except InvalidTokenError:
        raise
    except (jwt.PyJWTError, httpx.HTTPError, ValueError) as exc:
        raise InvalidTokenError(str(exc)) from exc
    return CurrentUser(
        id=str(claims["sub"]),
        email=claims.get("email"),
        role=str(claims.get("role", AUDIENCE)),
        raw_token=token,
    )
