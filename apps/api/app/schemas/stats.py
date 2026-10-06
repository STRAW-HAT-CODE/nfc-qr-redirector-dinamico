"""Modelos de salida de /v1/links/{id}/stats y /v1/orgs/{org}/stats (contrato para T047)."""

from datetime import date
from enum import StrEnum

from pydantic import BaseModel, Field


class StatsGroup(StrEnum):
    day = "day"
    channel = "channel"
    country = "country"
    device = "device"


class StatsTotals(BaseModel):
    scans: int
    # Suma de los únicos diarios (la sal del ip_hash rota a diario); en org, suma por enlace.
    unique_visitors: int


class StatsPoint(BaseModel):
    """Un punto de la serie.

    key: fecha ISO (day) · qr|nfc|direct (channel) · código ISO-3166 alfa-2, "unknown" u "other"
    (country) · nombre de dispositivo, "unknown" u "other" (device).
    unique_visitors solo viene informado en group=day (null en el resto).
    """

    key: str
    scans: int
    unique_visitors: int | None = None


class StatsOut(BaseModel):
    group: StatsGroup
    from_: date = Field(serialization_alias="from")
    to: date
    totals: StatsTotals
    series: list[StatsPoint]

    model_config = {"populate_by_name": True}
