"""Diseño y descargas del QR de un enlace (docs/04-api.md). Router fino; lógica en services."""

from typing import Annotated, Literal
from urllib.parse import quote
from uuid import UUID

from fastapi import APIRouter, Depends, File, Header, Query, UploadFile
from fastapi.responses import Response

from app.auth import CurrentUser
from app.core.config import Settings, get_settings
from app.db import UserDB
from app.deps import Role, get_current_user, get_db, get_org_id, require_role
from app.errors import ApiError
from app.middleware.body_limit import MAX_BODY_BYTES
from app.schemas.qr import DesignIn, DesignOut
from app.services.print_templates import MAX_TITLE_LEN
from app.services.qr_designs import MEDIA, QrDesignService
from app.services.qr_render import MAX_LOGO_BYTES, MAX_SIZE, MIN_SIZE

router = APIRouter(prefix="/v1/links/{link_id}", tags=["qr"])


def get_service(
    db: Annotated[UserDB, Depends(get_db)],
    settings: Annotated[Settings, Depends(get_settings)],
    org_id: Annotated[UUID, Depends(get_org_id)],
    user: Annotated[CurrentUser, Depends(get_current_user)],
) -> QrDesignService:
    return QrDesignService(db, settings, org_id, user.raw_token)


Svc = Annotated[QrDesignService, Depends(get_service)]


def limit_content_length(content_length: Annotated[int | None, Header()] = None) -> None:
    """Rechaza por Content-Length declarado (el middleware cubre chunked)."""
    if content_length is not None and content_length > MAX_BODY_BYTES:
        raise ApiError(413, "payload_too_large", "El cuerpo supera el límite de 1 MB")


@router.get("/design", response_model=DesignOut, dependencies=[Depends(require_role(Role.viewer))])
async def get_design(link_id: UUID, svc: Svc) -> DesignOut:
    return await svc.get_design(link_id)


@router.put("/design", response_model=DesignOut, dependencies=[Depends(require_role(Role.editor))])
async def put_design(link_id: UUID, body: DesignIn, svc: Svc) -> DesignOut:
    return await svc.put_design(link_id, body)


@router.get("/design/logo", dependencies=[Depends(require_role(Role.viewer))])
async def get_logo(link_id: UUID, svc: Svc) -> Response:
    png = await svc.get_logo(link_id)
    return Response(
        content=png,
        media_type="image/png",
        headers={"Cache-Control": "private, no-store", "X-Content-Type-Options": "nosniff"},
    )


@router.post(
    "/design/logo",
    response_model=DesignOut,
    status_code=201,
    dependencies=[Depends(limit_content_length), Depends(require_role(Role.editor))],
)
async def upload_logo(link_id: UUID, svc: Svc, file: Annotated[UploadFile, File()]) -> DesignOut:
    data = await file.read(MAX_LOGO_BYTES + 1)
    if len(data) > MAX_LOGO_BYTES:
        raise ApiError(413, "logo_too_large", "El logo supera 1 MB")
    return await svc.set_logo(link_id, data)


@router.delete(
    "/design/logo", response_model=DesignOut, dependencies=[Depends(require_role(Role.editor))]
)
async def delete_logo(link_id: UUID, svc: Svc) -> DesignOut:
    return await svc.delete_logo(link_id)


@router.get("/qr.{fmt}", dependencies=[Depends(require_role(Role.viewer))])
async def download_qr(
    link_id: UUID,
    fmt: Literal["png", "svg", "pdf"],
    svc: Svc,
    size: Annotated[int, Query(ge=MIN_SIZE, le=MAX_SIZE)] = 1024,
    template: Annotated[
        Literal["none", "sticker", "display", "poster", "google_review"], Query()
    ] = "none",
    title: Annotated[str | None, Query(min_length=1, max_length=MAX_TITLE_LEN)] = None,
) -> Response:
    """`template` ≠ none: pieza imprimible (mm reales; PNG a 300 dpi, `size` se ignora)."""
    content, slug, warnings = await svc.render(link_id, fmt, size, template, title)
    suffix = "qr" if template == "none" else template
    headers = {
        "Content-Disposition": f'attachment; filename="{slug}-{suffix}.{fmt}"',
        "Cache-Control": "private, no-store",
        "X-Content-Type-Options": "nosniff",
    }
    if warnings:
        headers["X-QR-Warnings"] = ",".join(quote(w) for w in warnings)  # ASCII, separado por comas
    return Response(content=content, media_type=MEDIA[fmt], headers=headers)
