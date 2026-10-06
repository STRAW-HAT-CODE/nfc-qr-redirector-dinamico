"""Lógica de orgs y miembros (DQR-01). Todo con el JWT del usuario (RLS)."""

from typing import Any
from uuid import UUID

import httpx

from app.db import PostgrestError, UserDB
from app.errors import ApiError


def map_db_error(exc: PostgrestError, *, conflict: tuple[str, str] | None = None) -> ApiError:
    """Traduce errores de PostgREST/BD a ApiError.

    P0001+hint last_owner → 409 last_owner · 42501 → 403 · 23505 → 409 (`conflict`)
    · 23503 (FK) → 404. Cualquier otro → 502 sin filtrar detalles de la BD.
    """
    if exc.code == "P0001" and exc.hint == "last_owner":
        return ApiError(409, "last_owner", "No se puede quitar ni degradar al último owner")
    if exc.code == "42501":
        return ApiError(403, "forbidden", "No tienes permiso para esta operación")
    if exc.code == "23505":
        code, msg = conflict or ("conflict", "El recurso ya existe")
        return ApiError(409, code, msg)
    if exc.code == "23503":
        return ApiError(404, "not_found", "Recurso no encontrado")
    return ApiError(502, "upstream_error", "Error al consultar la base de datos")


async def _guard[T](coro: Any, *, conflict: tuple[str, str] | None = None) -> T:
    try:
        return await coro  # type: ignore[no-any-return]
    except PostgrestError as exc:
        raise map_db_error(exc, conflict=conflict) from None
    except httpx.HTTPError:
        raise ApiError(502, "upstream_error", "Error al consultar la base de datos") from None


async def list_my_orgs(db: UserDB, user_id: str) -> list[dict[str, Any]]:
    rows: list[dict[str, Any]] = await _guard(
        db.select(
            "memberships",
            {
                "select": "role,organizations(id,name,slug,plan,status,created_at)",
                "user_id": f"eq.{user_id}",
                "order": "created_at.asc",
            },
        )
    )
    return [{**r["organizations"], "role": r["role"]} for r in rows if r.get("organizations")]


async def create_org(db: UserDB, name: str, slug: str) -> dict[str, Any]:
    result: Any = await _guard(
        db.rpc("create_organization", {"p_name": name, "p_slug": slug}),
        conflict=("slug_taken", "El slug ya está en uso"),
    )
    org = result[0] if isinstance(result, list) and result else result
    if not isinstance(org, dict):
        raise ApiError(502, "upstream_error", "Respuesta inesperada de la base de datos")
    return org


async def list_members(db: UserDB, org_id: UUID) -> list[dict[str, Any]]:
    rows: list[dict[str, Any]] = await _guard(
        db.select(
            "memberships",
            {
                "select": "org_id,user_id,role,created_at",
                "org_id": f"eq.{org_id}",
                "order": "created_at.asc",
            },
        )
    )
    return rows


async def add_member(
    db: UserDB, org_id: UUID, *, user_id: UUID | None, email: str | None, role: str
) -> dict[str, Any]:
    if user_id is None:
        # MVP: con el JWT del usuario no se puede resolver un email (auth.users no
        # está expuesto). Requiere una RPC de db-architect; ver PR.
        raise ApiError(501, "email_lookup_unavailable", "Añadir por email aún no está disponible")
    rows: list[dict[str, Any]] = await _guard(
        db.insert("memberships", {"org_id": str(org_id), "user_id": str(user_id), "role": role}),
        conflict=("already_member", "El usuario ya es miembro"),
    )
    return rows[0]


async def _member_exists(db: UserDB, org_id: UUID, user_id: UUID) -> bool:
    rows: list[dict[str, Any]] = await _guard(
        db.select(
            "memberships",
            {
                "select": "user_id",
                "org_id": f"eq.{org_id}",
                "user_id": f"eq.{user_id}",
                "limit": "1",
            },
        )
    )
    return bool(rows)


async def _empty_result_error(db: UserDB, org_id: UUID, user_id: UUID) -> ApiError:
    """Sin filas afectadas: 404 si el miembro no existe, 403 si RLS lo bloqueó."""
    if await _member_exists(db, org_id, user_id):
        return ApiError(403, "insufficient_role", "No puedes modificar a este miembro")
    return ApiError(404, "member_not_found", "Miembro no encontrado")


async def change_role(db: UserDB, org_id: UUID, user_id: UUID, role: str) -> dict[str, Any]:
    rows: list[dict[str, Any]] = await _guard(
        db.update(
            "memberships",
            {"org_id": f"eq.{org_id}", "user_id": f"eq.{user_id}"},
            {"role": role},
        )
    )
    if not rows:
        raise await _empty_result_error(db, org_id, user_id)
    return rows[0]


async def remove_member(db: UserDB, org_id: UUID, user_id: UUID) -> None:
    rows: list[dict[str, Any]] = await _guard(
        db.delete("memberships", {"org_id": f"eq.{org_id}", "user_id": f"eq.{user_id}"})
    )
    if not rows:
        raise await _empty_result_error(db, org_id, user_id)
