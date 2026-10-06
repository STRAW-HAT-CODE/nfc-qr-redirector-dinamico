"""Modelos de entrada/salida de /v1/links/{id}/nfc-tags."""

from datetime import datetime
from typing import Annotated
from uuid import UUID

from pydantic import BaseModel, ConfigDict, StringConstraints

Label = Annotated[str, StringConstraints(strip_whitespace=True, min_length=1, max_length=80)]
Location = Annotated[str, StringConstraints(strip_whitespace=True, max_length=120)]
# El formato real (hex de 4/7/10 bytes) lo normaliza y valida la BD; aquí solo un tope.
Uid = Annotated[str, StringConstraints(strip_whitespace=True, max_length=40)]


class NfcTagCreate(BaseModel):
    model_config = ConfigDict(extra="forbid")

    label: Label
    location: Location | None = None
    uid: Uid | None = None


class NfcTagUpdate(BaseModel):
    """Solo los campos enviados cambian; `location`/`uid` null explícito = borrar."""

    model_config = ConfigDict(extra="forbid")

    label: Label | None = None
    location: Location | None = None
    uid: Uid | None = None


class NfcTagOut(BaseModel):
    id: UUID
    link_id: UUID
    org_id: UUID
    label: str
    location: str | None
    uid: str | None
    created_at: datetime
    ndef_url: str
    ndef_bytes: int
    ndef_fits: bool
    ndef_warning: str | None


class NfcTagList(BaseModel):
    items: list[NfcTagOut]
