"""GET /v1/me: identidad y si es platform admin (para la UI)."""

from typing import Annotated

from fastapi import APIRouter, Depends

from app.auth import CurrentUser
from app.db import UserDB
from app.deps import get_current_user, get_db
from app.schemas.admin import MeOut
from app.services import admin as svc

router = APIRouter(prefix="/v1/me", tags=["me"])


@router.get("", response_model=MeOut)
async def me(
    user: Annotated[CurrentUser, Depends(get_current_user)],
    db: Annotated[UserDB, Depends(get_db)],
) -> MeOut:
    return MeOut(
        user_id=user.id, email=user.email, is_platform_admin=await svc.is_platform_admin(db)
    )
