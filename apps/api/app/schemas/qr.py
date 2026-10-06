"""Modelos de /v1/links/{id}/design y descargas QR."""

from datetime import datetime
from typing import Annotated, Literal

from pydantic import BaseModel, ConfigDict, Field, StringConstraints

Hex = Annotated[str, StringConstraints(pattern=r"^#(?:[0-9a-fA-F]{3}|[0-9a-fA-F]{6})$")]
FrameText = Annotated[str, StringConstraints(strip_whitespace=True, max_length=30)]


class DesignIn(BaseModel):
    """Diseño completo (PUT). El logo se gestiona aparte (POST/DELETE …/design/logo)."""

    model_config = ConfigDict(extra="forbid")

    fg: Hex = "#000000"
    bg: Hex = "#ffffff"
    ecc_level: Literal["L", "M", "Q", "H"] = "M"
    frame: Literal["none", "simple", "rounded", "label"] = "none"
    module_style: Literal["square", "rounded", "dots"] = "square"
    margin: Annotated[int, Field(ge=0, le=16)] = 4
    frame_text: FrameText | None = None


class DesignOut(BaseModel):
    link_id: str
    fg: str
    bg: str
    ecc_level: str
    frame: str
    module_style: str
    margin: int
    frame_text: str | None
    has_logo: bool
    is_default: bool
    updated_at: datetime | None
    warnings: list[str]
