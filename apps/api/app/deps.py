"""Dependencias FastAPI: usuario actual, organización activa y rol mínimo."""

from collections.abc import AsyncIterator, Callable, Coroutine
from enum import IntEnum
from typing import Annotated, Any
from uuid import UUID

import httpx
from fastapi import Depends, Header

from app.auth import CurrentUser, InvalidTokenError, verify_token
from app.core.config import Settings, get_settings
from app.db import UserDB
from app.errors import ApiError


class Role(IntEnum):
    """Jerarquía viewer < editor < admin < owner (igual que public.org_role)."""

    viewer = 1
    editor = 2
    admin = 3
    owner = 4


async def get_current_user(
    settings: Annotated[Settings, Depends(get_settings)],
    authorization: Annotated[str | None, Header()] = None,
) -> CurrentUser:
    scheme, _, token = (authorization or "").partition(" ")
    if scheme.lower() != "bearer" or not token.strip():
        raise ApiError(
            401, "unauthorized", "Falta el token de acceso", {"WWW-Authenticate": "Bearer"}
        )
    try:
        return await verify_token(token.strip(), settings)
    except InvalidTokenError:
        raise ApiError(
            401, "invalid_token", "Token inválido o expirado", {"WWW-Authenticate": "Bearer"}
        ) from None


def get_org_id(x_org_id: Annotated[str | None, Header()] = None) -> UUID:
    if x_org_id is None:
        raise ApiError(400, "invalid_org_id", "Falta el header X-Org-Id")
    try:
        return UUID(x_org_id)
    except ValueError:
        raise ApiError(400, "invalid_org_id", "X-Org-Id debe ser un UUID válido") from None


async def get_db(
    user: Annotated[CurrentUser, Depends(get_current_user)],
    settings: Annotated[Settings, Depends(get_settings)],
) -> AsyncIterator[UserDB]:
    db = UserDB(settings, user.raw_token)
    try:
        yield db
    finally:
        await db.aclose()


async def fetch_role(db: UserDB, org_id: UUID, user_id: str) -> Role | None:
    """Rol del usuario en la org según RLS (sin fila => no es miembro)."""
    try:
        rows = await db.select(
            "memberships",
            {
                "select": "role",
                "org_id": f"eq.{org_id}",
                "user_id": f"eq.{user_id}",
                "limit": "1",
            },
        )
    except httpx.HTTPError:
        raise ApiError(502, "upstream_error", "No se pudo consultar la membresía") from None
    if not rows:
        return None
    try:
        return Role[str(rows[0]["role"])]
    except KeyError:
        return None


def require_role(
    min_role: Role | str,
) -> Callable[..., Coroutine[Any, Any, CurrentUser]]:
    """Dependencia: 403 si el usuario no es miembro de la org o su rol es menor."""
    required = Role[min_role] if isinstance(min_role, str) else min_role

    async def checker(
        user: Annotated[CurrentUser, Depends(get_current_user)],
        org_id: Annotated[UUID, Depends(get_org_id)],
        db: Annotated[UserDB, Depends(get_db)],
    ) -> CurrentUser:
        role = await fetch_role(db, org_id, user.id)
        if role is None:
            raise ApiError(403, "not_a_member", "No perteneces a esta organización")
        if role < required:
            raise ApiError(403, "insufficient_role", f"Se requiere el rol {required.name}")
        return user

    return checker
