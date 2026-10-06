"""Tests de /v1/.../stats sin red: BD falsa (RPC + scan_events) y un test respx del cliente real."""

import asyncio
from collections.abc import Iterator
from datetime import UTC, date, datetime, timedelta
from typing import Any
from uuid import uuid4

import httpx
import pytest
import respx
from fastapi.testclient import TestClient

from app.auth import CurrentUser
from app.core.config import Settings, get_settings
from app.db import UserDB
from app.deps import get_current_user, get_db
from app.main import app

ORG = str(uuid4())
LINK = str(uuid4())
USER = str(uuid4())
H = {"X-Org-Id": ORG}


def row(day: str, scans: int, uv: int, qr: int, nfc: int, direct: int) -> dict[str, Any]:
    return {
        "day": day,
        "scans": scans,
        "unique_visitors": uv,
        "qr": qr,
        "nfc": nfc,
        "direct": direct,
    }


ROWS = [row("2026-10-01", 5, 4, 3, 2, 0), row("2026-10-03", 3, 3, 0, 1, 2)]


class FakeDB:
    def __init__(self, role: str | None, events: list[dict[str, Any]] | None = None) -> None:
        self.role = role
        self.events = events or []
        self.rpcs: list[tuple[str, dict[str, Any]]] = []
        self.selects: list[tuple[str, dict[str, str]]] = []

    async def select(self, table: str, params: dict[str, str]) -> list[dict[str, Any]]:
        self.selects.append((table, params))
        if table == "memberships":
            return [{"role": self.role}] if self.role else []
        if table == "dynamic_links":
            return [{"id": LINK}] if params["id"] == f"eq.{LINK}" else []
        return self.events

    async def rpc(self, fn: str, args: dict[str, Any]) -> Any:
        self.rpcs.append((fn, args))
        return ROWS


def make(db: FakeDB) -> Iterator[TestClient]:
    app.dependency_overrides[get_settings] = lambda: Settings()
    app.dependency_overrides[get_db] = lambda: db
    app.dependency_overrides[get_current_user] = lambda: CurrentUser(
        id=USER, email=None, role="authenticated", raw_token="t"
    )
    yield TestClient(app)
    app.dependency_overrides.clear()


@pytest.fixture
def db() -> FakeDB:
    return FakeDB("viewer")


@pytest.fixture
def client(db: FakeDB) -> Iterator[TestClient]:
    yield from make(db)


Q = "from=2026-10-01&to=2026-10-04"


def test_group_day_fills_zeros_and_totals(client: TestClient, db: FakeDB) -> None:
    r = client.get(f"/v1/links/{LINK}/stats?{Q}", headers=H)
    assert r.status_code == 200, r.text
    b = r.json()
    assert b["from"] == "2026-10-01" and b["to"] == "2026-10-04" and b["group"] == "day"
    assert b["totals"] == {"scans": 8, "unique_visitors": 7}
    assert [(p["key"], p["scans"]) for p in b["series"]] == [
        ("2026-10-01", 5),
        ("2026-10-02", 0),
        ("2026-10-03", 3),
        ("2026-10-04", 0),
    ]
    assert db.rpcs == [
        ("link_stats", {"p_link_id": LINK, "p_from": "2026-10-01", "p_to": "2026-10-04"})
    ]


def test_group_channel(client: TestClient) -> None:
    b = client.get(f"/v1/links/{LINK}/stats?{Q}&group=channel", headers=H).json()
    assert {p["key"]: p["scans"] for p in b["series"]} == {"qr": 3, "nfc": 3, "direct": 2}


def test_group_country_top_and_unknown(db: FakeDB) -> None:
    events = [
        {"country": f"{chr(65 + i // 26)}{chr(65 + i % 26)}", "scans": 30 - i} for i in range(22)
    ]
    events.append({"country": None, "scans": 4})
    db.events = events
    for c in make(db):
        b = c.get(f"/v1/links/{LINK}/stats?{Q}&group=country", headers=H).json()
    keys = [p["key"] for p in b["series"]]
    assert len(keys) == 22 and keys[-2:] == ["other", "unknown"]
    assert b["series"][-2]["scans"] == (30 - 20) + (30 - 21)
    assert b["series"][-1]["scans"] == 4
    _, params = db.selects[-1]
    assert params["is_bot"] == "eq.false" and params["link_id"] == f"eq.{LINK}"
    assert params["select"] == "country,scans:count()"


def test_group_device_org(db: FakeDB) -> None:
    db.events = [{"device": "mobile", "scans": 6}, {"device": "desktop", "scans": 2}]
    for c in make(db):
        r = c.get(f"/v1/orgs/{ORG}/stats?{Q}&group=device")
    b = r.json()
    assert [(p["key"], p["scans"]) for p in b["series"]] == [("mobile", 6), ("desktop", 2)]
    assert db.rpcs[0][0] == "org_stats"
    assert "link_id" not in db.selects[-1][1]


def test_org_path_mismatch_header(client: TestClient) -> None:
    r = client.get(f"/v1/orgs/{ORG}/stats", headers={"X-Org-Id": str(uuid4())})
    assert r.status_code == 400 and r.json()["error"]["code"] == "org_mismatch"


@pytest.mark.parametrize(
    "qs",
    [
        "from=2026-10-05&to=2026-10-01",
        "from=2025-01-01&to=2026-10-01",
        "from=nope",
        "group=hour",
    ],
)
def test_invalid_params_422(client: TestClient, qs: str) -> None:
    r = client.get(f"/v1/links/{LINK}/stats?{qs}", headers=H)
    assert r.status_code == 422


def test_max_range_366_ok(client: TestClient) -> None:
    r = client.get(f"/v1/links/{LINK}/stats?from=2025-10-01&to=2026-10-01", headers=H)
    assert r.status_code == 200 and len(r.json()["series"]) == 366


def test_default_range_30_days(client: TestClient) -> None:
    b = client.get(f"/v1/links/{LINK}/stats", headers=H).json()
    assert len(b["series"]) == 30
    assert b["to"] == datetime.now(UTC).date().isoformat()
    assert date.fromisoformat(b["from"]) == date.fromisoformat(b["to"]) - timedelta(days=29)


def test_403_without_membership() -> None:
    for c in make(FakeDB(None)):
        assert c.get(f"/v1/links/{LINK}/stats", headers=H).status_code == 403
        assert c.get(f"/v1/orgs/{ORG}/stats").status_code == 403


def test_link_of_other_org_404(client: TestClient) -> None:
    r = client.get(f"/v1/links/{uuid4()}/stats", headers=H)
    assert r.status_code == 404 and r.json()["error"]["code"] == "link_not_found"


@respx.mock
def test_userdb_aggregate_query_params() -> None:
    asyncio.run(_userdb_aggregate())


async def _userdb_aggregate() -> None:
    """El cliente real envía el JWT y los filtros de agregación esperados."""
    from app.services.stats import StatsService

    route = respx.get("https://x.supabase.co/rest/v1/scan_events").mock(
        return_value=httpx.Response(200, json=[{"device": "mobile", "scans": 3}])
    )
    rpc = respx.post("https://x.supabase.co/rest/v1/rpc/org_stats").mock(
        return_value=httpx.Response(200, json=ROWS)
    )
    udb = UserDB(Settings(supabase_url="https://x.supabase.co", supabase_anon_key="k"), "jwt")
    out = await StatsService(udb).stats(
        group=app_group("device"), frm=date(2026, 10, 1), to=date(2026, 10, 4), org_id=uuid4()
    )
    await udb.aclose()
    assert rpc.called and route.calls[0].request.headers["authorization"] == "Bearer jwt"
    assert "is_bot=eq.false" in str(route.calls[0].request.url)
    assert out.series[0].key == "mobile"


def app_group(v: str) -> Any:
    from app.schemas.stats import StatsGroup

    return StatsGroup(v)
