"""Modelos de /v1/links/{id}/design y descargas QR."""

from datetime import datetime
from typing import Annotated, Any, Literal

from pydantic import (
    BaseModel,
    ConfigDict,
    Field,
    StrictBool,
    StringConstraints,
    model_validator,
)

Hex = Annotated[str, StringConstraints(pattern=r"^#(?:[0-9a-fA-F]{3}|[0-9a-fA-F]{6})$")]
FrameText = Annotated[str, StringConstraints(strip_whitespace=True, max_length=30)]


class DesignStyleIn(BaseModel):
    """Subconjunto editable de `style` (lista blanca). Contrato de la web: `style.logo_preset`."""

    model_config = ConfigDict(extra="forbid")

    logo_preset: Literal["google"] | None = None
    bg_transparent: StrictBool | None = None


class DesignIn(BaseModel):
    """Diseño completo (PUT). El logo se gestiona aparte (POST/DELETE …/design/logo)."""

    model_config = ConfigDict(extra="forbid")

    fg: Hex = "#000000"
    # "transparent": se guarda bg "#ffffff" + style.bg_transparent (sin tocar la BD).
    bg: Hex | Literal["transparent"] = "#ffffff"
    ecc_level: Literal["L", "M", "Q", "H"] = "M"
    frame: Literal["none", "simple", "rounded", "label"] = "none"
    module_style: Literal["square", "rounded", "dots"] = "square"
    margin: Annotated[int, Field(ge=0, le=16)] = 4
    frame_text: FrameText | None = None
    # Preset de logo incluido (lista blanca: solo "google"); fuerza ECC H y gana sobre logo_path.
    logo_preset: Literal["google"] | None = None
    # Alias aceptado por compatibilidad con la web: {"style": {"logo_preset": ...}}.
    style: DesignStyleIn | None = None
    # Derivado de bg == "transparent" o style.bg_transparent (no se acepta como campo suelto).
    bg_transparent: bool = Field(default=False, exclude=True)

    @model_validator(mode="after")
    def _style_preset(self) -> "DesignIn":
        wants = self.bg == "transparent"
        if self.style is not None and self.style.bg_transparent is not None:
            if wants and not self.style.bg_transparent:
                raise ValueError("bg y style.bg_transparent no coinciden")
            wants = wants or self.style.bg_transparent
        if wants:
            self.bg = "#ffffff"
        self.bg_transparent = wants
        if self.style is not None and "logo_preset" in self.style.model_fields_set:
            if self.logo_preset is not None and self.logo_preset != self.style.logo_preset:
                raise ValueError("logo_preset y style.logo_preset no coinciden")
            self.logo_preset = self.style.logo_preset
        return self


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
    logo_preset: str | None = None
    style: dict[str, Any] = Field(default_factory=dict)
    is_default: bool
    updated_at: datetime | None
    warnings: list[str]
