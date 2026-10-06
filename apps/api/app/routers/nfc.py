"""Etiquetas NFC de un enlace (docs/04-api.md). Router fino; la lógica vive en services/nfc."""

from typing import Annotated
from uuid import UUID

from fastapi import APIRouter, Depends

from app.core.config import Settings, get_settings
from app.db import UserDB
from app.deps import Role, get_db, get_org_id, require_role
from app.schemas.nfc import NfcTagCreate, NfcTagList, NfcTagOut, NfcTagUpdate
from app.services.nfc import NfcService

router = APIRouter(prefix="/v1/links/{link_id}/nfc-tags", tags=["nfc"])


def get_service(
    db: Annotated[UserDB, Depends(get_db)],
    settings: Annotated[Settings, Depends(get_settings)],
    org_id: Annotated[UUID, Depends(get_org_id)],
) -> NfcService:
    return NfcService(db, settings, org_id)


Svc = Annotated[NfcService, Depends(get_service)]


@router.get("", response_model=NfcTagList, dependencies=[Depends(require_role(Role.viewer))])
async def list_tags(link_id: UUID, svc: Svc) -> NfcTagList:
    return await svc.list_tags(link_id)


@router.post(
    "",
    response_model=NfcTagOut,
    status_code=201,
    dependencies=[Depends(require_role(Role.editor))],
)
async def create_tag(link_id: UUID, body: NfcTagCreate, svc: Svc) -> NfcTagOut:
    return await svc.create(link_id, body)


@router.patch(
    "/{tag_id}", response_model=NfcTagOut, dependencies=[Depends(require_role(Role.editor))]
)
async def update_tag(link_id: UUID, tag_id: UUID, body: NfcTagUpdate, svc: Svc) -> NfcTagOut:
    return await svc.update(link_id, tag_id, body)


@router.delete(
    "/{tag_id}", response_model=NfcTagOut, dependencies=[Depends(require_role(Role.admin))]
)
async def delete_tag(link_id: UUID, tag_id: UUID, svc: Svc) -> NfcTagOut:
    """Borra la etiqueta; sus escaneos se conservan con tag_id NULL."""
    return await svc.delete(link_id, tag_id)
