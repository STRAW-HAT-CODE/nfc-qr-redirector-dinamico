"""Esquemas pydantic v2 de orgs y miembros (docs/04-api.md)."""

from datetime import datetime
from enum import StrEnum
from typing import Annotated, Self
from uuid import UUID

from pydantic import (
    BaseModel,
    ConfigDict,
    Field,
    StringConstraints,
    field_validator,
    model_validator,
)

SLUG_PATTERN = r"^[a-z0-9][a-z0-9-]{1,61}[a-z0-9]$"  # igual que organizations_slug_check
EMAIL_PATTERN = r"^[^@\s]+@[^@\s]+\.[^@\s]+$"


class OrgRole(StrEnum):
    viewer = "viewer"
    editor = "editor"
    admin = "admin"
    owner = "owner"


class OrgCreate(BaseModel):
    model_config = ConfigDict(extra="forbid")

    name: Annotated[str, StringConstraints(strip_whitespace=True, min_length=1, max_length=120)]
    slug: str = Field(pattern=SLUG_PATTERN)

    @field_validator("slug", mode="before")
    @classmethod
    def _normalize_slug(cls, v: object) -> object:
        # La RPC hace lower(btrim(slug)); se valida ya normalizado.
        return v.strip().lower() if isinstance(v, str) else v


class OrgOut(BaseModel):
    id: UUID
    name: str
    slug: str
    plan: str
    status: str
    created_at: datetime


class MyOrgOut(OrgOut):
    role: OrgRole


class MemberCreate(BaseModel):
    """Añade un miembro existente por `user_id` o `email` (invitación por email: V2)."""

    model_config = ConfigDict(extra="forbid")

    user_id: UUID | None = None
    email: Annotated[str, StringConstraints(strip_whitespace=True, max_length=254)] | None = Field(
        default=None, pattern=EMAIL_PATTERN
    )
    role: OrgRole = OrgRole.viewer

    @model_validator(mode="after")
    def _exactly_one_identifier(self) -> Self:
        if (self.user_id is None) == (self.email is None):
            raise ValueError("indica exactamente uno de user_id o email")
        return self


class MemberUpdate(BaseModel):
    model_config = ConfigDict(extra="forbid")

    role: OrgRole


class MemberOut(BaseModel):
    org_id: UUID
    user_id: UUID
    role: OrgRole
    created_at: datetime
