"""Esquemas pydantic v2 de /v1/admin y /v1/me (docs/modules/DQR-09-plataforma.md)."""

from datetime import datetime
from enum import StrEnum
from typing import Annotated, Any, Self
from uuid import UUID

from pydantic import BaseModel, ConfigDict, StringConstraints, model_validator

Plan = Annotated[str, StringConstraints(strip_whitespace=True, min_length=1, max_length=40)]


class OrgStatus(StrEnum):
    active = "active"
    suspended = "suspended"


class MeOut(BaseModel):
    user_id: str
    email: str | None
    is_platform_admin: bool


class AdminOrgOut(BaseModel):
    id: UUID
    name: str
    slug: str
    plan: str
    status: str
    limits: dict[str, Any] | None = None
    created_at: datetime
    members: int = 0
    links: int = 0
    scans_30d: int = 0


class AdminOrgUpdate(BaseModel):
    """Solo se envían los campos a cambiar; al menos uno."""

    model_config = ConfigDict(extra="forbid")

    plan: Plan | None = None
    status: OrgStatus | None = None
    limits: dict[str, Any] | None = None

    @model_validator(mode="after")
    def _at_least_one(self) -> Self:
        if not self.model_fields_set or all(
            getattr(self, f) is None for f in ("plan", "status", "limits")
        ):
            raise ValueError("indica al menos uno de plan, status o limits")
        return self


class AdminOrgRow(BaseModel):
    id: UUID
    name: str
    slug: str
    plan: str
    status: str
    limits: dict[str, Any] | None = None
    created_at: datetime


class BlockedDomainIn(BaseModel):
    model_config = ConfigDict(extra="forbid")

    domain: Annotated[str, StringConstraints(strip_whitespace=True, min_length=3, max_length=253)]


class BlockedDomainOut(BaseModel):
    domain: str
    created_at: datetime


class LinkSuspendIn(BaseModel):
    model_config = ConfigDict(extra="forbid")

    suspended: bool
    reason: Annotated[str, StringConstraints(strip_whitespace=True, max_length=500)] | None = None


class AdminLinkOut(BaseModel):
    id: UUID
    org_id: UUID
    org_name: str | None = None
    slug: str
    name: str | None = None
    destination_url: str
    status: str
    created_at: datetime


class AdminLinkSuspendOut(BaseModel):
    id: UUID
    org_id: UUID
    slug: str
    status: str
    suspended_at: datetime | None = None
    suspended_reason: str | None = None
