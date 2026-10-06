"""Métricas de enlaces y organizaciones (docs/04-api.md). Router fino; lógica en services/stats."""

from datetime import date
from typing import Annotated
from uuid import UUID

from fastapi import APIRouter, Depends, Query

from app.db import UserDB
from app.deps import Role, get_db, get_org_id, get_path_org_id, require_org_role, require_role
from app.schemas.stats import StatsGroup, StatsOut
from app.services.stats import StatsService, resolve_range

router = APIRouter(tags=["stats"])


def get_service(db: Annotated[UserDB, Depends(get_db)]) -> StatsService:
    return StatsService(db)


Svc = Annotated[StatsService, Depends(get_service)]
From = Annotated[date | None, Query(alias="from", description="Fecha ISO (UTC); por defecto to-29")]
To = Annotated[date | None, Query(description="Fecha ISO (UTC); por defecto hoy")]


@router.get(
    "/v1/links/{link_id}/stats",
    response_model=StatsOut,
    response_model_by_alias=True,
    dependencies=[Depends(require_role(Role.viewer))],
)
async def link_stats(
    link_id: UUID,
    svc: Svc,
    org_id: Annotated[UUID, Depends(get_org_id)],
    frm: From = None,
    to: To = None,
    group: StatsGroup = StatsGroup.day,
) -> StatsOut:
    start, end = resolve_range(frm, to)
    return await svc.stats(group=group, frm=start, to=end, link_id=link_id, org_id=org_id)


@router.get(
    "/v1/orgs/{org}/stats",
    response_model=StatsOut,
    response_model_by_alias=True,
    dependencies=[Depends(require_org_role(Role.viewer))],
)
async def org_stats(
    svc: Svc,
    org_id: Annotated[UUID, Depends(get_path_org_id)],
    frm: From = None,
    to: To = None,
    group: StatsGroup = StatsGroup.day,
) -> StatsOut:
    start, end = resolve_range(frm, to)
    return await svc.stats(group=group, frm=start, to=end, org_id=org_id)
