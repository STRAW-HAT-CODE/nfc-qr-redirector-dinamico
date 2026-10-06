"""Tests de /v1/links sin red: UserDB falso que imita RLS y triggers de la BD."""

from collections.abc import Iterator
from datetime import UTC, datetime
from typing import Any
from uuid import uuid4

import pytest
from fastapi.testclient import TestClient

from app.auth import CurrentUser
from app.core.config import Settings, get_settings
from app.db import PostgrestError
from app.deps import get_current_user, get_db
from app.main import app

ORG = str(uuid4())
OTHER_ORG = str(uuid4())
USER = str(uuid4())
BASE = "https://go.example.com"
RANK = {"viewer": 1, "editor": 2, "admin": 3, "owner": 4}


class FakeDB:
    """Tabla en memoria con las reglas relevantes de la migración T018."""

    def __init__(self, role: str | None) -> None:
        self.role = role
        self.links: list[dict[str, Any]] = []
        self.history: list[dict[str, Any]] = []
        self.selects: list[tuple[str, dict[str, str]]] = []
        self.inserted: list[dict[str, Any]] = []
        self.blocked = {"evil.example"}
        self._n = 0

    def _can(self, role: str) -> bool:
        return self.role is not None and RANK[self.role] >= RANK[role]

    @staticmethod
    def _eq(params: dict[str, str], key: str) -> str | None:
        v = params.get(key)
        return v[3:] if v and v.startswith("eq.") else None

    def _filter(self, rows: list[dict[str, Any]], params: dict[str, str]) -> list[dict[str, Any]]:
        for key in ("id", "org_id", "status", "link_id"):
            val = self._eq(params, key)
            if val is not None:
                rows = [r for r in rows if str(r.get(key)) == val]
        if name := params.get("name"):
            term = name.removeprefix("ilike.").strip("*").lower()
            rows = [r for r in rows if term in r["name"].lower()]
        return rows

    async def rpc(self, fn: str, args: dict[str, Any]) -> Any:
        assert fn == "my_effective_role"
        return self.role

    async def select(self, table: str, params: dict[str, str]) -> list[dict[str, Any]]:
        self.selects.append((table, params))
        rows = self.links if table == "dynamic_links" else self.history
        if not self._can("viewer"):
            return []
        rows = self._filter(rows, params)
        rows = sorted(
            rows, key=lambda r: str(r.get("created_at") or r.get("changed_at")), reverse=True
        )
        off = int(params.get("offset", 0))
        lim = int(params.get("limit", 1000))
        return rows[off : off + lim]

    def _check_url(self, row: dict[str, Any]) -> None:
        for f in ("destination_url", "fallback_url"):
            url = row.get(f)
            if url and any(d in url for d in self.blocked):
                raise PostgrestError(400, "23514", "blocked", "url_blocked_domain")

    async def insert(self, table: str, row: dict[str, Any]) -> list[dict[str, Any]]:
        assert table == "dynamic_links"
        self.inserted.append(row)
        assert "slug" not in row and "id" not in row
        if not self._can("editor") or (row["status"] == "archived" and not self._can("admin")):
            raise PostgrestError(403, "42501", "new row violates row-level security policy")
        self._check_url(row)
        self._n += 1
        now = datetime(2026, 1, 1, 0, 0, self._n, tzinfo=UTC).isoformat()
        full = {
            "id": str(uuid4()),
            "slug": f"Ab3dE{self._n:02d}",
            "fallback_url": None,
            "starts_at": None,
            "expires_at": None,
            "created_by": USER,
            "created_at": now,
            "updated_at": now,
            **row,
        }
        self.links.append(full)
        return [full]

    async def update(
        self, table: str, params: dict[str, str], values: dict[str, Any]
    ) -> list[dict[str, Any]]:
        rows = self._filter(self.links, params)
        out = []
        for r in rows:
            if not self._can("editor") or (r["status"] == "archived" and not self._can("admin")):
                continue  # USING falla: sin filas
            if values.get("status") == "archived" and not self._can("admin"):
                raise PostgrestError(403, "42501", "new row violates row-level security policy")
            self._check_url(values)
            if "destination_url" in values and values["destination_url"] != r["destination_url"]:
                self.history.append(
                    {
                        "id": len(self.history) + 1,
                        "link_id": r["id"],
                        "org_id": r["org_id"],
                        "old_url": r["destination_url"],
                        "new_url": values["destination_url"],
                        "changed_by": USER,
                        "changed_at": datetime(2026, 2, 1, tzinfo=UTC).isoformat(),
                    }
                )
            r.update(values)
            out.append(r)
        return out


@pytest.fixture
def db() -> FakeDB:
    return FakeDB("editor")


@pytest.fixture
def client(db: FakeDB) -> Iterator[TestClient]:
    app.dependency_overrides[get_settings] = lambda: Settings(public_redirect_base_url=BASE)
    app.dependency_overrides[get_db] = lambda: db
    app.dependency_overrides[get_current_user] = lambda: CurrentUser(
        id=USER, email=None, role="authenticated", raw_token="t"
    )
    yield TestClient(app)
    app.dependency_overrides.clear()


H = {"X-Org-Id": ORG}
BODY = {"name": "Menú", "destination_url": "https://example.com/menu"}


def create(client: TestClient, **extra: Any) -> dict[str, Any]:
    r = client.post("/v1/links", headers=H, json={**BODY, **extra})
    assert r.status_code == 201, r.text
    data: dict[str, Any] = r.json()
    return data


# --- crear -------------------------------------------------------------------
def test_create_returns_db_slug_and_short_url(client: TestClient, db: FakeDB) -> None:
    data = create(client)
    assert data["slug"] == db.links[0]["slug"]
    assert data["short_url"] == f"{BASE}/r/{data['slug']}"
    assert db.inserted[0]["org_id"] == ORG


def test_create_rejects_slug_in_body(client: TestClient) -> None:
    r = client.post("/v1/links", headers=H, json={**BODY, "slug": "abcdefg"})
    assert r.status_code == 422


def test_create_normalizes_url(client: TestClient, db: FakeDB) -> None:
    create(client, destination_url="HTTPS://Example.COM/x")
    assert db.inserted[0]["destination_url"] == "https://example.com/x"


@pytest.mark.parametrize(
    ("field", "url", "code"),
    [
        ("destination_url", "ftp://example.com", "url_scheme_not_allowed"),
        ("destination_url", "http://localhost/x", "url_private_host"),
        ("destination_url", "https://u:p@example.com", "url_credentials_not_allowed"),
        ("destination_url", f"{BASE}/r/abc", "url_self_redirect"),
        ("fallback_url", "http://10.0.0.1/", "url_private_host"),
    ],
)
def test_create_url_policy_422(
    client: TestClient, db: FakeDB, field: str, url: str, code: str
) -> None:
    r = client.post("/v1/links", headers=H, json={**BODY, field: url})
    assert r.status_code == 422
    assert r.json()["error"]["code"] == code
    assert db.inserted == []  # se valida ANTES de enviar


def test_create_blocked_domain_from_db(client: TestClient) -> None:
    r = client.post(
        "/v1/links", headers=H, json={**BODY, "destination_url": "https://evil.example/"}
    )
    assert r.status_code == 422
    assert r.json()["error"]["code"] == "url_blocked_domain"


def test_create_invalid_window_422(client: TestClient) -> None:
    r = client.post(
        "/v1/links",
        headers=H,
        json={**BODY, "starts_at": "2026-02-01T00:00:00Z", "expires_at": "2026-01-01T00:00:00Z"},
    )
    assert r.status_code == 422


def test_create_empty_name_422(client: TestClient) -> None:
    assert client.post("/v1/links", headers=H, json={**BODY, "name": "  "}).status_code == 422


def test_create_archived_as_editor_403(client: TestClient) -> None:
    r = client.post("/v1/links", headers=H, json={**BODY, "status": "archived"})
    assert r.status_code == 403


# --- roles ---------------------------------------------------------------------
def test_viewer_can_read_not_write(db: FakeDB, client: TestClient) -> None:
    link = create(client)
    db.role = "viewer"
    assert client.get("/v1/links", headers=H).status_code == 200
    assert client.get(f"/v1/links/{link['id']}", headers=H).status_code == 200
    assert client.get(f"/v1/links/{link['id']}/history", headers=H).status_code == 200
    assert client.post("/v1/links", headers=H, json=BODY).status_code == 403
    assert client.patch(f"/v1/links/{link['id']}", headers=H, json={"name": "x"}).status_code == 403
    dest = {"destination_url": "https://example.com/n"}
    assert (
        client.patch(f"/v1/links/{link['id']}/destination", headers=H, json=dest).status_code == 403
    )
    assert client.delete(f"/v1/links/{link['id']}", headers=H).status_code == 403


def test_non_member_403(db: FakeDB, client: TestClient) -> None:
    db.role = None
    r = client.get("/v1/links", headers=H)
    assert r.status_code == 403
    assert r.json()["error"]["code"] == "not_a_member"


def test_missing_org_header_400(client: TestClient) -> None:
    assert client.get("/v1/links").status_code == 400


# --- detalle / 404 ---------------------------------------------------------------
def test_get_not_found_404(client: TestClient) -> None:
    r = client.get(f"/v1/links/{uuid4()}", headers=H)
    assert r.status_code == 404
    assert r.json()["error"]["code"] == "link_not_found"


def test_other_org_link_is_404(client: TestClient) -> None:
    link = create(client)
    r = client.get(f"/v1/links/{link['id']}", headers={"X-Org-Id": OTHER_ORG})
    assert r.status_code == 404
    assert r.json()["error"]["code"] == "link_not_found"


# --- PATCH / archivar ----------------------------------------------------------------
def test_patch_name_fallback_and_clear(client: TestClient) -> None:
    link = create(client)
    r = client.patch(
        f"/v1/links/{link['id']}",
        headers=H,
        json={"name": "Nuevo", "fallback_url": "https://example.com/fb", "status": "paused"},
    )
    assert r.status_code == 200
    assert (r.json()["name"], r.json()["status"]) == ("Nuevo", "paused")
    assert r.json()["fallback_url"] == "https://example.com/fb"
    r = client.patch(f"/v1/links/{link['id']}", headers=H, json={"fallback_url": None})
    assert r.json()["fallback_url"] is None


def test_patch_rejects_destination_and_slug(client: TestClient) -> None:
    link = create(client)
    for body in ({"slug": "abcdefg"}, {"destination_url": "https://example.com/z"}):
        assert client.patch(f"/v1/links/{link['id']}", headers=H, json=body).status_code == 422


def test_patch_bad_fallback_422(client: TestClient) -> None:
    link = create(client)
    r = client.patch(f"/v1/links/{link['id']}", headers=H, json={"fallback_url": "javascript:x"})
    assert r.status_code == 422
    assert r.json()["error"]["code"] == "url_scheme_not_allowed"


def test_archive_via_patch_as_editor_403(client: TestClient) -> None:
    link = create(client)
    r = client.patch(f"/v1/links/{link['id']}", headers=H, json={"status": "archived"})
    assert r.status_code == 403
    assert r.json()["error"]["code"] == "insufficient_role"


def test_archive_via_patch_as_admin(db: FakeDB, client: TestClient) -> None:
    link = create(client)
    db.role = "admin"
    r = client.patch(f"/v1/links/{link['id']}", headers=H, json={"status": "archived"})
    assert r.status_code == 200
    assert r.json()["status"] == "archived"


def test_editor_cannot_unarchive_403(db: FakeDB, client: TestClient) -> None:
    link = create(client)
    db.role = "admin"
    client.delete(f"/v1/links/{link['id']}", headers=H)
    db.role = "editor"
    r = client.patch(f"/v1/links/{link['id']}", headers=H, json={"status": "active"})
    assert r.status_code == 403


def test_delete_archives_without_removing(db: FakeDB, client: TestClient) -> None:
    link = create(client)
    db.role = "admin"
    r = client.delete(f"/v1/links/{link['id']}", headers=H)
    assert r.status_code == 200
    assert r.json()["status"] == "archived"
    assert len(db.links) == 1


def test_delete_as_editor_403(client: TestClient) -> None:
    link = create(client)
    assert client.delete(f"/v1/links/{link['id']}", headers=H).status_code == 403


def test_delete_unknown_404_as_admin(db: FakeDB, client: TestClient) -> None:
    db.role = "admin"
    assert client.delete(f"/v1/links/{uuid4()}", headers=H).status_code == 404


# --- destino e historial ----------------------------------------------------------------
def test_change_destination_creates_history(client: TestClient) -> None:
    link = create(client)
    r = client.patch(
        f"/v1/links/{link['id']}/destination",
        headers=H,
        json={"destination_url": "https://example.com/nuevo"},
    )
    assert r.status_code == 200
    assert r.json()["destination_url"] == "https://example.com/nuevo"
    assert r.json()["slug"] == link["slug"]
    h = client.get(f"/v1/links/{link['id']}/history", headers=H).json()
    assert h["items"][0]["old_url"] == "https://example.com/menu"
    assert h["items"][0]["new_url"] == "https://example.com/nuevo"


def test_change_destination_policy_and_blocklist(client: TestClient, db: FakeDB) -> None:
    link = create(client)
    url = f"/v1/links/{link['id']}/destination"
    r = client.patch(url, headers=H, json={"destination_url": "http://127.0.0.1/"})
    assert (r.status_code, r.json()["error"]["code"]) == (422, "url_private_host")
    r = client.patch(url, headers=H, json={"destination_url": "https://a.evil.example/"})
    assert (r.status_code, r.json()["error"]["code"]) == (422, "url_blocked_domain")
    assert db.history == []


def test_history_unknown_link_404(client: TestClient) -> None:
    assert client.get(f"/v1/links/{uuid4()}/history", headers=H).status_code == 404


# --- listado ------------------------------------------------------------------------------
def test_list_pagination_and_filters(client: TestClient) -> None:
    for i in range(5):
        create(client, name=f"Link {i}")
    create(client, name="Otro", status="paused")
    r = client.get("/v1/links", headers=H, params={"limit": 2}).json()
    assert [i["name"] for i in r["items"]] == ["Otro", "Link 4"]
    assert r["has_more"] is True
    r = client.get("/v1/links", headers=H, params={"limit": 2, "offset": 4}).json()
    assert len(r["items"]) == 2
    assert r["has_more"] is False
    assert all("short_url" in i for i in r["items"])
    r = client.get("/v1/links", headers=H, params={"q": "otro"}).json()
    assert [i["name"] for i in r["items"]] == ["Otro"]
    r = client.get("/v1/links", headers=H, params={"status": "paused"}).json()
    assert [i["name"] for i in r["items"]] == ["Otro"]


@pytest.mark.parametrize("params", [{"limit": 0}, {"limit": 101}, {"offset": -1}, {"status": "x"}])
def test_list_invalid_params_422(client: TestClient, params: dict[str, Any]) -> None:
    assert client.get("/v1/links", headers=H, params=params).status_code == 422


def test_list_search_escapes_wildcards(client: TestClient, db: FakeDB) -> None:
    client.get("/v1/links", headers=H, params={"q": "50%_*off"})
    _, params = db.selects[-1]
    assert params["name"] == r"ilike.*50\%\_off*"
    assert params["limit"] == "21"
