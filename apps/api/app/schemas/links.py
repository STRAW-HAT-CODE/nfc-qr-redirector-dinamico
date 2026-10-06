"""Modelos de entrada/salida de /v1/links."""

from datetime import datetime
from enum import StrEnum
from typing import Annotated, Self
from uuid import UUID

from pydantic import BaseModel, ConfigDict, Field, StringConstraints, model_validator

Name = Annotated[str, StringConstraints(strip_whitespace=True, min_length=1, max_length=120)]


class LinkStatus(StrEnum):
    active = "active"
    paused = "paused"
    archived = "archived"


class _Window(BaseModel):
    starts_at: datetime | None = None
    expires_at: datetime | None = None

    @model_validator(mode="after")
    def _check_window(self) -> Self:
        if self.starts_at and self.expires_at and self.starts_at >= self.expires_at:
            raise ValueError("starts_at debe ser anterior a expires_at")
        return self


class LinkCreate(_Window):
    """Sin `slug`: lo genera la BD (ADR-0006). Campos extra se rechazan."""

    model_config = ConfigDict(extra="forbid")

    name: Name
    destination_url: str
    fallback_url: str | None = None
    status: LinkStatus = LinkStatus.active


class LinkUpdate(_Window):
    model_config = ConfigDict(extra="forbid")

    name: Name | None = None
    status: LinkStatus | None = None
    fallback_url: str | None = None  # null explícito = quitar el fallback


class DestinationUpdate(BaseModel):
    model_config = ConfigDict(extra="forbid")

    destination_url: str


class LinkOut(BaseModel):
    id: UUID
    org_id: UUID
    slug: str
    short_url: str
    name: str
    destination_url: str
    fallback_url: str | None
    status: LinkStatus
    starts_at: datetime | None
    expires_at: datetime | None
    created_by: UUID | None
    created_at: datetime
    updated_at: datetime


class LinkPage(BaseModel):
    items: list[LinkOut]
    limit: int
    offset: int
    has_more: bool


class HistoryOut(BaseModel):
    id: int
    link_id: UUID
    old_url: str
    new_url: str
    changed_by: UUID | None
    changed_at: datetime


class HistoryPage(BaseModel):
    items: list[HistoryOut]
    limit: int
    offset: int
    has_more: bool


MAX_LIMIT = 100
DEFAULT_LIMIT = 20
LimitParam = Annotated[int, Field(ge=1, le=MAX_LIMIT)]
