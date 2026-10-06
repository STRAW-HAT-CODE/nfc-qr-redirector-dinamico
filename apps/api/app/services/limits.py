"""Errores de límites de plan (DQR-T053) → ApiError.

La BD hace cumplir los límites (ADR-0006): triggers en dynamic_links, memberships,
nfc_tags y qr_designs lanzan P0001 con hint ``plan_limit_reached``, y
create_organization lanza P0001 con hint ``org_limit`` (máx. 5 orgs propias).

Se responde 409 y no 402: no hay cobro en la API y docs/04-api.md ya define 409
como conflicto con el estado del recurso; el cliente lo distingue por ``code``.
El mensaje de la BD lo redactamos nosotros (recurso y máximo), así que se
reenvía tal cual; si llegara vacío se usa uno genérico.
"""

from app.db import PostgrestError
from app.errors import ApiError

_LIMITS: dict[str, tuple[str, str]] = {
    "plan_limit_reached": ("plan_limit_reached", "Has alcanzado el límite de tu plan"),
    "org_limit": ("org_limit_reached", "Has alcanzado el máximo de organizaciones propias"),
}


def plan_limit_error(exc: PostgrestError) -> ApiError | None:
    """409 si ``exc`` es un límite de plan u organizaciones; si no, ``None``."""
    if exc.code != "P0001" or exc.hint not in _LIMITS:
        return None
    code, fallback = _LIMITS[exc.hint]
    return ApiError(409, code, exc.message.strip() or fallback)
