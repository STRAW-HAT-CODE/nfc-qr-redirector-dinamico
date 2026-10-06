"""CRUD de enlaces dinámicos (docs/04-api.md). Router fino; la lógica vive en services/links."""

from typing import Annotated
from uuid import UUID

from fastapi import APIRouter, Depends, Query

from app.core.config import Settings, get_settings
from app.db import UserDB
from app.deps import Role, get_db, get_org_id, require_role
from app.schemas.links import (
    DEFAULT_LIMIT,
    DestinationUpdate,
    HistoryPage,
    LimitParam,
    LinkCreate,
    LinkOut,
    LinkPage,
    LinkStatus,
    LinkUpdate,
)
from app.services.links import LinksService

router = APIRouter(prefix="/v1/links", tags=["links"])


def get_service(
    db: Annotated[UserDB, Depends(get_db)],
    settings: Annotated[Settings, Depends(get_settings)],
    org_id: Annotated[UUID, Depends(get_org_id)],
) -> LinksService:
    return LinksService(db, settings, org_id)


Svc = Annotated[LinksService, Depends(get_service)]


@router.get("", response_model=LinkPage, dependencies=[Depends(require_role(Role.viewer))])
async def list_links(
    svc: Svc,
    q: Annotated[str | None, Query(max_length=120)] = None,
    status: LinkStatus | None = None,
    limit: LimitParam = DEFAULT_LIMIT,
    offset: Annotated[int, Query(ge=0)] = 0,
) -> LinkPage:
    return await svc.list_links(q=q, status=status, limit=limit, offset=offset)


@router.post(
    "",
    response_model=LinkOut,
    status_code=201,
    dependencies=[Depends(require_role(Role.editor))],
)
async def create_link(body: LinkCreate, svc: Svc) -> LinkOut:
    return await svc.create(body)


@router.get("/{link_id}", response_model=LinkOut, dependencies=[Depends(require_role(Role.viewer))])
async def get_link(link_id: UUID, svc: Svc) -> LinkOut:
    return await svc.get(link_id)


@router.patch(
    "/{link_id}", response_model=LinkOut, dependencies=[Depends(require_role(Role.editor))]
)
async def update_link(link_id: UUID, body: LinkUpdate, svc: Svc) -> LinkOut:
    return await svc.update(link_id, body)


@router.delete(
    "/{link_id}", response_model=LinkOut, dependencies=[Depends(require_role(Role.admin))]
)
async def archive_link(link_id: UUID, svc: Svc) -> LinkOut:
    """Archiva (status=archived); no borra la fila."""
    return await svc.archive(link_id)


@router.patch(
    "/{link_id}/destination",
    response_model=LinkOut,
    dependencies=[Depends(require_role(Role.editor))],
)
async def update_destination(link_id: UUID, body: DestinationUpdate, svc: Svc) -> LinkOut:
    return await svc.set_destination(link_id, body.destination_url)


@router.get(
    "/{link_id}/history",
    response_model=HistoryPage,
    dependencies=[Depends(require_role(Role.viewer))],
)
async def link_history(
    link_id: UUID,
    svc: Svc,
    limit: LimitParam = DEFAULT_LIMIT,
    offset: Annotated[int, Query(ge=0)] = 0,
) -> HistoryPage:
    return await svc.history(link_id, limit=limit, offset=offset)
