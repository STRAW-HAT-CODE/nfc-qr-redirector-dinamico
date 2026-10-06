"""Métricas: rollups vía RPC (day/channel) y agregación sobre scan_events (country/device)."""

from datetime import UTC, date, datetime, timedelta
from typing import Any
from uuid import UUID

import httpx

from app.db import PostgrestError, UserDB
from app.errors import ApiError
from app.schemas.stats import StatsGroup, StatsOut, StatsPoint, StatsTotals

DEFAULT_DAYS = 30
MAX_DAYS = 366
CHANNELS = ("qr", "nfc", "direct")


def resolve_range(frm: date | None, to: date | None) -> tuple[date, date]:
    """Por defecto, últimos 30 días (hoy UTC incluido). Máximo 366 días; from ≤ to."""
    today = datetime.now(UTC).date()
    end = to or today
    start = frm or end - timedelta(days=DEFAULT_DAYS - 1)
    if start > end:
        raise ApiError(422, "invalid_range", "from debe ser anterior o igual a to")
    if (end - start).days + 1 > MAX_DAYS:
        raise ApiError(422, "invalid_range", f"El rango máximo es de {MAX_DAYS} días")
    return start, end


class StatsService:
    def __init__(self, db: UserDB) -> None:
        self._db = db

    async def _run(self, op: Any) -> Any:
        try:
            return await op
        except PostgrestError as exc:
            if exc.code == "22023":
                raise ApiError(422, "invalid_range", "Rango de fechas no válido") from exc
            if exc.code == "42501":
                raise ApiError(
                    403, "insufficient_role", "No tienes permiso para esta operación"
                ) from exc
            raise ApiError(502, "upstream_error", "Error al consultar la base de datos") from exc
        except httpx.HTTPError:
            raise ApiError(502, "upstream_error", "No se pudo consultar la base de datos") from None

    async def link_exists(self, link_id: UUID, org_id: UUID) -> None:
        rows = await self._run(
            self._db.select(
                "dynamic_links",
                {"select": "id", "id": f"eq.{link_id}", "org_id": f"eq.{org_id}", "limit": "1"},
            )
        )
        if not rows:
            raise ApiError(404, "link_not_found", "Enlace no encontrado")

    async def stats(
        self,
        *,
        group: StatsGroup,
        frm: date,
        to: date,
        link_id: UUID | None = None,
        org_id: UUID,
    ) -> StatsOut:
        if link_id is not None:
            await self.link_exists(link_id, org_id)
            rows = await self._run(
                self._db.rpc(
                    "link_stats", {"p_link_id": str(link_id), "p_from": str(frm), "p_to": str(to)}
                )
            )
        else:
            rows = await self._run(
                self._db.rpc(
                    "org_stats", {"p_org_id": str(org_id), "p_from": str(frm), "p_to": str(to)}
                )
            )
        totals = StatsTotals(
            scans=sum(int(r["scans"]) for r in rows),
            unique_visitors=sum(int(r["unique_visitors"]) for r in rows),
        )
        if group is StatsGroup.day:
            series = self._by_day(rows, frm, to)
        elif group is StatsGroup.channel:
            series = [StatsPoint(key=c, scans=sum(int(r[c]) for r in rows)) for c in CHANNELS]
        else:
            series = await self._by_column(group.value, frm, to, link_id, org_id)
        return StatsOut(group=group, from_=frm, to=to, totals=totals, series=series)

    @staticmethod
    def _by_day(rows: list[dict[str, Any]], frm: date, to: date) -> list[StatsPoint]:
        by: dict[str, dict[str, Any]] = {str(r["day"]): r for r in rows}
        out: list[StatsPoint] = []
        d = frm
        while d <= to:
            r = by.get(d.isoformat())
            out.append(
                StatsPoint(
                    key=d.isoformat(),
                    scans=int(r["scans"]) if r else 0,
                    unique_visitors=int(r["unique_visitors"]) if r else 0,
                )
            )
            d += timedelta(days=1)
        return out

    async def _by_column(
        self, column: str, frm: date, to: date, link_id: UUID | None, org_id: UUID
    ) -> list[StatsPoint]:
        """Desglose por country/device vía RPC link_breakdown/org_breakdown.

        La BD aplica RLS (SECURITY INVOKER), excluye bots y devuelve top 20 + other + unknown.
        """
        args: dict[str, Any] = {"p_from": str(frm), "p_to": str(to), "p_dimension": column}
        if link_id is not None:
            fn, args["p_link_id"] = "link_breakdown", str(link_id)
        else:
            fn, args["p_org_id"] = "org_breakdown", str(org_id)
        rows = await self._run(self._db.rpc(fn, args))
        return [
            StatsPoint(
                key=str(r.get("value") or "unknown"),
                scans=int(r["scans"]),
                unique_visitors=int(r["unique_visitors"])
                if r.get("unique_visitors") is not None
                else None,
            )
            for r in rows
        ]
