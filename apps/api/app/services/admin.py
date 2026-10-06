"""Lógica de la consola de plataforma (DQR-T054). Todo vía RPC con el JWT del usuario.

La BD hace cumplir `private.is_platform_admin()`: 42501 => 403 `not_platform_admin`.
"""

from typing import Any
from uuid import UUID

import httpx

from app.db import PostgrestError, UserDB
from app.errors import ApiError

_NIL_UUID = "00000000-0000-0000-0000-000000000000"


def map_admin_error(exc: PostgrestError) -> ApiError:
    if exc.code == "42501":
        return ApiError(403, "not_platform_admin", "Requiere ser administrador de plataforma")
    if exc.code in ("P0002", "23503"):
        return ApiError(404, "not_found", "Recurso no encontrado")
    if exc.code in ("23514", "22023", "22P02", "22001"):
        return ApiError(422, "validation_error", "Datos inválidos")
    return ApiError(502, "upstream_error", "Error al consultar la base de datos")


async def _rpc(db: UserDB, fn: str, args: dict[str, Any]) -> Any:
    try:
        return await db.rpc(fn, args)
    except PostgrestError as exc:
        raise map_admin_error(exc) from None
    except httpx.HTTPError:
        raise ApiError(502, "upstream_error", "Error al consultar la base de datos") from None


def _one(result: Any) -> dict[str, Any]:
    row = result[0] if isinstance(result, list) and result else result
    if not isinstance(row, dict):
        raise ApiError(404, "not_found", "Recurso no encontrado")
    return row


def _rows(result: Any) -> list[dict[str, Any]]:
    return result if isinstance(result, list) else []


async def is_platform_admin(db: UserDB) -> bool:
    """`my_effective_role` devuelve 'owner' en cualquier org solo para platform admins.

    Una org inexistente (nil UUID) no tiene membresías, así que 'owner' implica admin.
    """
    role = await _rpc(db, "my_effective_role", {"p_org_id": _NIL_UUID})
    return bool(role == "owner")


async def list_orgs(db: UserDB, q: str | None, limit: int, offset: int) -> list[dict[str, Any]]:
    args: dict[str, Any] = {"p_q": q or None, "p_limit": limit, "p_offset": offset}
    return _rows(await _rpc(db, "admin_list_orgs", args))


async def update_org(
    db: UserDB,
    org_id: UUID,
    *,
    plan: str | None,
    status: str | None,
    limits: dict[str, Any] | None,
) -> dict[str, Any]:
    args = {"p_org_id": str(org_id), "p_plan": plan, "p_status": status, "p_limits": limits}
    return _one(await _rpc(db, "admin_update_org", args))


async def list_blocked_domains(db: UserDB) -> list[dict[str, Any]]:
    return _rows(await _rpc(db, "admin_list_blocked_domains", {}))


async def block_domain(db: UserDB, domain: str) -> None:
    await _rpc(db, "admin_block_domain", {"p_domain": domain})


async def unblock_domain(db: UserDB, domain: str) -> None:
    await _rpc(db, "admin_unblock_domain", {"p_domain": domain})


async def find_links(db: UserDB, slug: str) -> list[dict[str, Any]]:
    return _rows(await _rpc(db, "admin_find_link", {"p_slug": slug}))


async def set_link_status(db: UserDB, link_id: UUID, status: str) -> dict[str, Any]:
    args = {"p_link_id": str(link_id), "p_status": status}
    return _one(await _rpc(db, "admin_set_link_status", args))
