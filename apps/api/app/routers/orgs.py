"""Orgs y miembros (docs/04-api.md). Routers finos; la lógica vive en services/orgs."""

from typing import Annotated
from uuid import UUID

from fastapi import APIRouter, Depends, Response

from app.auth import CurrentUser
from app.db import UserDB
from app.deps import Role, get_current_user, get_db, get_path_org_id, require_org_role
from app.schemas.orgs import (
    MemberCreate,
    MemberOut,
    MemberUpdate,
    MyOrgOut,
    OrgCreate,
    OrgOut,
)
from app.services import orgs as svc

router = APIRouter(prefix="/v1/orgs", tags=["orgs"])

CurrentUserDep = Annotated[CurrentUser, Depends(get_current_user)]
DB = Annotated[UserDB, Depends(get_db)]
OrgId = Annotated[UUID, Depends(get_path_org_id)]
AdminDep = Depends(require_org_role(Role.admin))


@router.get("", response_model=list[MyOrgOut])
async def list_orgs(user: CurrentUserDep, db: DB) -> list[MyOrgOut]:
    return [MyOrgOut(**o) for o in await svc.list_my_orgs(db, user.id)]


@router.post("", response_model=OrgOut, status_code=201)
async def create_org(body: OrgCreate, _: CurrentUserDep, db: DB) -> OrgOut:
    return OrgOut(**await svc.create_org(db, body.name, body.slug))


@router.get("/{org}/members", response_model=list[MemberOut], dependencies=[AdminDep])
async def list_members(org_id: OrgId, db: DB) -> list[MemberOut]:
    return [MemberOut(**m) for m in await svc.list_members(db, org_id)]


@router.post("/{org}/members", response_model=MemberOut, status_code=201, dependencies=[AdminDep])
async def add_member(org_id: OrgId, body: MemberCreate, db: DB) -> MemberOut:
    row = await svc.add_member(
        db, org_id, user_id=body.user_id, email=body.email, role=body.role.value
    )
    return MemberOut(**row)


@router.patch("/{org}/members/{user}", response_model=MemberOut, dependencies=[AdminDep])
async def change_member_role(org_id: OrgId, user: UUID, body: MemberUpdate, db: DB) -> MemberOut:
    return MemberOut(**await svc.change_role(db, org_id, user, body.role.value))


@router.delete("/{org}/members/{user}", status_code=204, dependencies=[AdminDep])
async def remove_member(org_id: OrgId, user: UUID, db: DB) -> Response:
    await svc.remove_member(db, org_id, user)
    return Response(status_code=204)
