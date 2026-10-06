"""Generación y validación de slugs base62 (DQR-02).

Funciones puras. La unicidad la garantiza la BD (409 en la API).
"""

import secrets
import string

SLUG_ALPHABET = string.digits + string.ascii_uppercase + string.ascii_lowercase
SLUG_LENGTH = 7

_ALPHABET_SET = frozenset(SLUG_ALPHABET)


def generate_slug() -> str:
    """Slug aleatorio de SLUG_LENGTH caracteres base62 usando un CSPRNG."""
    return "".join(secrets.choice(SLUG_ALPHABET) for _ in range(SLUG_LENGTH))


def is_valid_slug(s: object) -> bool:
    """True si `s` es un str de exactamente SLUG_LENGTH caracteres base62 (solo ASCII)."""
    return isinstance(s, str) and len(s) == SLUG_LENGTH and all(c in _ALPHABET_SET for c in s)
