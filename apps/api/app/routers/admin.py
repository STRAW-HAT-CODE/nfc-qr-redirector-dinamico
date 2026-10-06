"""Consola de plataforma /v1/admin/* (solo platform admins; la BD lo hace cumplir)."""

from typing import Annotated
from uuid import UUID

from fastapi import APIRouter, Depends, Query, Response

from app.db import UserDB
from app.deps import get_current_user, get_db
from app.schemas.admin import (
    AdminLinkOut,
    AdminLinkStatusOut,
    AdminOrgOut,
    AdminOrgRow,
    AdminOrgUpdate,
    BlockedDomainIn,
    BlockedDomainOut,
    LinkStatusUpdate,
)
from app.services import admin as svc

router = APIRouter(prefix="/v1/admin", tags=["admin"], dependencies=[Depends(get_current_user)])

DB = Annotated[UserDB, Depends(get_db)]


@router.get("/orgs", response_model=list[AdminOrgOut])
async def list_orgs(
    db: DB,
    q: Annotated[str | None, Query(max_length=120)] = None,
    limit: Annotated[int, Query(ge=1, le=200)] = 50,
    offset: Annotated[int, Query(ge=0)] = 0,
) -> list[AdminOrgOut]:
    return [AdminOrgOut(**r) for r in await svc.list_orgs(db, q, limit, offset)]


@router.patch("/orgs/{org_id}", response_model=AdminOrgRow)
async def update_org(org_id: UUID, body: AdminOrgUpdate, db: DB) -> AdminOrgRow:
    row = await svc.update_org(
        db,
        org_id,
        plan=body.plan,
        status=body.status.value if body.status else None,
        limits=body.limits,
    )
    return AdminOrgRow(**row)


@router.get("/blocked-domains", response_model=list[BlockedDomainOut])
async def list_blocked_domains(db: DB) -> list[BlockedDomainOut]:
    return [BlockedDomainOut(**r) for r in await svc.list_blocked_domains(db)]


@router.post("/blocked-domains", status_code=204)
async def block_domain(body: BlockedDomainIn, db: DB) -> Response:
    await svc.block_domain(db, body.domain)
    return Response(status_code=204)


@router.delete("/blocked-domains", status_code=204)
async def unblock_domain(body: BlockedDomainIn, db: DB) -> Response:
    await svc.unblock_domain(db, body.domain)
    return Response(status_code=204)


@router.get("/links", response_model=list[AdminLinkOut])
async def find_links(
    db: DB, slug: Annotated[str, Query(min_length=1, max_length=64)]
) -> list[AdminLinkOut]:
    return [AdminLinkOut(**r) for r in await svc.find_links(db, slug)]


@router.patch("/links/{link_id}/status", response_model=AdminLinkStatusOut)
async def set_link_status(link_id: UUID, body: LinkStatusUpdate, db: DB) -> AdminLinkStatusOut:
    return AdminLinkStatusOut(**await svc.set_link_status(db, link_id, body.status.value))
