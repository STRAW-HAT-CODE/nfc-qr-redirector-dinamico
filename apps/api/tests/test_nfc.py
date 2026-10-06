"""Tests de /v1/links/{id}/nfc-tags sin red: UserDB falso que imita RLS y constraints."""

import re
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
from app.services.nfc import NTAG213_USABLE_BYTES, ndef_record_size

ORG = str(uuid4())
OTHER_ORG = str(uuid4())
USER = str(uuid4())
BASE = "https://go.example.com"
SLUG = "Ab3dE01"
RANK = {"viewer": 1, "editor": 2, "admin": 3, "owner": 4}
H = {"X-Org-Id": ORG}


class FakeDB:
    def __init__(self, role: str | None) -> None:
        self.role = role
        self.link_id = str(uuid4())
        self.links = [{"id": self.link_id, "org_id": ORG, "slug": SLUG}]
        self.tags: list[dict[str, Any]] = []
        self._n = 0

    def _can(self, role: str) -> bool:
        return self.role is not None and RANK[self.role] >= RANK[role]

    @staticmethod
    def _filter(rows: list[dict[str, Any]], params: dict[str, str]) -> list[dict[str, Any]]:
        for key in ("id", "org_id", "link_id"):
            v = params.get(key)
            if v and v.startswith("eq."):
                rows = [r for r in rows if str(r.get(key)) == v[3:]]
        return rows

    @staticmethod
    def _norm(values: dict[str, Any]) -> dict[str, Any]:
        out = dict(values)
        if isinstance(out.get("uid"), str):
            out["uid"] = re.sub(r"[:\s-]", "", out["uid"]).upper() or None
        if isinstance(out.get("location"), str):
            out["location"] = out["location"].strip() or None
        return out

    def _check_uid(self, org: str, uid: str | None, own: Any = None) -> None:
        if uid is None:
            return
        if not re.fullmatch(r"([0-9A-F]{8}|[0-9A-F]{14}|[0-9A-F]{20})", uid):
            raise PostgrestError(400, "23514", 'violates check constraint "nfc_tags_uid_check"')
        if any(t["org_id"] == org and t["uid"] == uid and t["id"] != own for t in self.tags):
            raise PostgrestError(409, "23505", "duplicate key nfc_tags_org_uid_key")

    async def rpc(self, fn: str, args: dict[str, Any]) -> Any:
        assert fn == "my_effective_role"
        return self.role

    async def select(self, table: str, params: dict[str, str]) -> list[dict[str, Any]]:
        rows = self.links if table == "dynamic_links" else self.tags
        if not self._can("viewer"):
            return []
        return sorted(
            self._filter(rows, params), key=lambda r: r.get("created_at", ""), reverse=True
        )

    async def insert(self, table: str, row: dict[str, Any]) -> list[dict[str, Any]]:
        assert table == "nfc_tags" and "id" not in row
        if not self._can("editor"):
            raise PostgrestError(403, "42501", "new row violates row-level security policy")
        row = self._norm(row)
        self._check_uid(row["org_id"], row["uid"])
        self._n += 1
        full = {
            "id": str(uuid4()),
            "created_at": datetime(2026, 1, 1, 0, 0, self._n, tzinfo=UTC).isoformat(),
            **row,
        }
        self.tags.append(full)
        return [full]

    async def update(
        self, table: str, params: dict[str, str], values: dict[str, Any]
    ) -> list[dict[str, Any]]:
        if not self._can("editor"):
            return []
        values = self._norm(values)
        out = []
        for r in self._filter(self.tags, params):
            self._check_uid(r["org_id"], values.get("uid"), r["id"])
            r.update(values)
            out.append(r)
        return out

    async def delete(self, table: str, params: dict[str, str]) -> list[dict[str, Any]]:
        if not self._can("admin"):
            return []
        gone = self._filter(self.tags, params)
        self.tags = [t for t in self.tags if t not in gone]
        return gone


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


def url(db: FakeDB, tag_id: str | None = None) -> str:
    base = f"/v1/links/{db.link_id}/nfc-tags"
    return f"{base}/{tag_id}" if tag_id else base


def create(client: TestClient, db: FakeDB, **body: Any) -> dict[str, Any]:
    r = client.post(url(db), headers=H, json={"label": "Mesa 1", **body})
    assert r.status_code == 201, r.text
    data: dict[str, Any] = r.json()
    return data


# --- ndef ------------------------------------------------------------------------
def test_ndef_size_uses_abbreviated_prefix() -> None:
    # 4 (cabecera+tipo) + 1 (prefijo 0x04) + resto sin "https://"
    assert ndef_record_size("https://a.io/r/x") == 4 + 1 + len("a.io/r/x")
    assert ndef_record_size("http://a.io") == 4 + 1 + len("a.io")
    assert ndef_record_size("ftp://a.io") == 4 + 1 + len("ftp://a.io")


def test_create_returns_ndef_url_and_fits_ntag213(client: TestClient, db: FakeDB) -> None:
    tag = create(client, db, location="Entrada", uid="04:a2:5b:1c:2d:3e:4f")
    assert tag["ndef_url"] == f"{BASE}/r/{SLUG}?c=n&t={tag['id']}"
    assert tag["ndef_bytes"] == ndef_record_size(tag["ndef_url"])
    assert tag["ndef_fits"] is True and tag["ndef_warning"] is None
    assert tag["uid"] == "04A25B1C2D3E4F"
    assert tag["location"] == "Entrada"


def test_domain_of_25_chars_fits(db: FakeDB, client: TestClient) -> None:
    host = "https://" + "a" * 13 + ".example.com"  # dominio de 25 caracteres
    app.dependency_overrides[get_settings] = lambda: Settings(public_redirect_base_url=host)
    tag = create(client, db)
    assert tag["ndef_bytes"] <= NTAG213_USABLE_BYTES
    assert tag["ndef_fits"] is True


def test_long_domain_warns(db: FakeDB, client: TestClient) -> None:
    host = "https://" + "a" * 110 + ".example.com"
    app.dependency_overrides[get_settings] = lambda: Settings(public_redirect_base_url=host)
    tag = create(client, db)
    assert tag["ndef_bytes"] > NTAG213_USABLE_BYTES
    assert tag["ndef_fits"] is False
    assert "NTAG215" in tag["ndef_warning"]


# --- listar / roles -----------------------------------------------------------------
def test_list_has_ndef_url_per_tag(client: TestClient, db: FakeDB) -> None:
    a, b = create(client, db, label="A"), create(client, db, label="B")
    db.role = "viewer"
    items = client.get(url(db), headers=H).json()["items"]
    assert [i["label"] for i in items] == ["B", "A"]
    assert {i["ndef_url"] for i in items} == {a["ndef_url"], b["ndef_url"]}


def test_roles(client: TestClient, db: FakeDB) -> None:
    tag = create(client, db)
    db.role = "viewer"
    assert client.get(url(db), headers=H).status_code == 200
    assert client.post(url(db), headers=H, json={"label": "x"}).status_code == 403
    assert client.patch(url(db, tag["id"]), headers=H, json={"label": "x"}).status_code == 403
    assert client.delete(url(db, tag["id"]), headers=H).status_code == 403
    db.role = "editor"
    assert client.patch(url(db, tag["id"]), headers=H, json={"label": "x"}).status_code == 200
    assert client.delete(url(db, tag["id"]), headers=H).status_code == 403
    db.role = "admin"
    assert client.delete(url(db, tag["id"]), headers=H).status_code == 200
    assert db.tags == []


def test_other_org_link_is_404(client: TestClient, db: FakeDB) -> None:
    tag = create(client, db)
    db.role = "admin"
    other = {"X-Org-Id": OTHER_ORG}
    for r in (
        client.get(url(db), headers=other),
        client.post(url(db), headers=other, json={"label": "x"}),
        client.patch(url(db, tag["id"]), headers=other, json={"label": "x"}),
        client.delete(url(db, tag["id"]), headers=other),
    ):
        assert r.status_code == 404
        assert r.json()["error"]["code"] == "link_not_found"


def test_unknown_link_404(client: TestClient) -> None:
    r = client.get(f"/v1/links/{uuid4()}/nfc-tags", headers=H)
    assert r.status_code == 404


# --- patch / delete -----------------------------------------------------------------
def test_patch_fields_and_clear(client: TestClient, db: FakeDB) -> None:
    tag = create(client, db, location="Entrada", uid="04A25B1C")
    r = client.patch(
        url(db, tag["id"]), headers=H, json={"label": "Mesa 2", "location": None, "uid": None}
    )
    assert r.status_code == 200
    data = r.json()
    assert (data["label"], data["location"], data["uid"]) == ("Mesa 2", None, None)
    assert data["ndef_url"] == tag["ndef_url"]  # la URL no cambia al editar


def test_patch_unknown_tag_404(client: TestClient, db: FakeDB) -> None:
    r = client.patch(url(db, str(uuid4())), headers=H, json={"label": "x"})
    assert r.status_code == 404
    assert r.json()["error"]["code"] == "nfc_tag_not_found"
    assert client.delete(url(db, str(uuid4())), headers=H).status_code in (403, 404)


def test_patch_empty_body_returns_tag(client: TestClient, db: FakeDB) -> None:
    tag = create(client, db)
    assert client.patch(url(db, tag["id"]), headers=H, json={}).json()["id"] == tag["id"]


# --- validación / conflictos ---------------------------------------------------------
def test_duplicate_uid_409_on_create_and_patch(client: TestClient, db: FakeDB) -> None:
    create(client, db, uid="04A25B1C")
    r = client.post(url(db), headers=H, json={"label": "B", "uid": "04:a2:5b:1c"})
    assert r.status_code == 409
    assert r.json()["error"]["code"] == "nfc_uid_conflict"
    other = create(client, db, label="C")
    r = client.patch(url(db, other["id"]), headers=H, json={"uid": "04A25B1C"})
    assert r.status_code == 409


def test_invalid_uid_422(client: TestClient, db: FakeDB) -> None:
    r = client.post(url(db), headers=H, json={"label": "A", "uid": "ZZ"})
    assert r.status_code == 422
    assert r.json()["error"]["code"] == "nfc_uid_invalid"


@pytest.mark.parametrize(
    "body",
    [
        {"label": "  "},
        {"label": "x" * 81},
        {"label": "a", "location": "x" * 121},
        {"label": "a", "x": 1},
    ],
)
def test_validation_422(client: TestClient, db: FakeDB, body: dict[str, Any]) -> None:
    assert client.post(url(db), headers=H, json=body).status_code == 422
