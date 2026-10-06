"""Tests de /v1/orgs sin red: FakeDB sobre get_db + respx para UserDB."""

import asyncio
from collections.abc import Iterator
from typing import Any
from uuid import uuid4

import httpx
import pytest
import respx
from fastapi.testclient import TestClient

from app.auth import CurrentUser
from app.core.config import Settings
from app.db import PostgrestError, UserDB
from app.deps import get_current_user, get_db
from app.main import app

USER_ID = str(uuid4())
ORG_ID = str(uuid4())
OTHER_ID = str(uuid4())
NOW = "2026-01-01T00:00:00Z"
ORG_ROW = {
    "id": ORG_ID,
    "name": "Acme",
    "slug": "acme",
    "plan": "free",
    "status": "active",
    "created_at": NOW,
}


def member(user_id: str, role: str) -> dict[str, Any]:
    return {"org_id": ORG_ID, "user_id": user_id, "role": role, "created_at": NOW}


class FakeDB:
    """Responde por tabla; `errors` fuerza un PostgrestError en una operación."""

    def __init__(self, my_role: str | None = "admin") -> None:
        self.my_role = my_role
        self.members: dict[str, dict[str, Any]] = {OTHER_ID: member(OTHER_ID, "viewer")}
        self.errors: dict[str, PostgrestError] = {}
        self.rpc_calls: list[tuple[str, dict[str, Any]]] = []
        self.blocked_by_rls = False

    def _maybe_raise(self, op: str) -> None:
        if op in self.errors:
            raise self.errors[op]

    async def select(self, table: str, params: dict[str, str]) -> list[dict[str, Any]]:
        if "organizations" in params.get("select", ""):
            return [{"role": "owner", "organizations": ORG_ROW}]
        if params.get("select") == "user_id":
            uid = params["user_id"].removeprefix("eq.")
            return [{"user_id": uid}] if uid in self.members else []
        return list(self.members.values())

    async def insert(self, table: str, row: dict[str, Any]) -> list[dict[str, Any]]:
        self._maybe_raise("insert")
        return [{**row, "created_at": NOW}]

    async def update(
        self, table: str, params: dict[str, str], values: dict[str, Any]
    ) -> list[dict[str, Any]]:
        self._maybe_raise("update")
        uid = params["user_id"].removeprefix("eq.")
        if self.blocked_by_rls or uid not in self.members:
            return []
        self.members[uid]["role"] = values["role"]
        return [self.members[uid]]

    async def delete(self, table: str, params: dict[str, str]) -> list[dict[str, Any]]:
        self._maybe_raise("delete")
        uid = params["user_id"].removeprefix("eq.")
        if self.blocked_by_rls or uid not in self.members:
            return []
        return [self.members.pop(uid)]

    async def rpc(self, fn: str, args: dict[str, Any]) -> Any:
        if fn == "my_effective_role":
            return self.my_role
        self.rpc_calls.append((fn, args))
        self._maybe_raise("rpc")
        return ORG_ROW


@pytest.fixture
def db() -> FakeDB:
    return FakeDB()


@pytest.fixture
def client(db: FakeDB) -> Iterator[TestClient]:
    app.dependency_overrides[get_current_user] = lambda: CurrentUser(
        id=USER_ID, email="u@example.com", role="authenticated", raw_token="jwt"
    )
    app.dependency_overrides[get_db] = lambda: db
    yield TestClient(app)
    app.dependency_overrides.clear()


def err(code: str, hint: str | None = None, status: int = 409) -> PostgrestError:
    return PostgrestError(status, code, "msg", hint)


# --- auth / roles -------------------------------------------------------------------------
def test_401_without_token() -> None:
    c = TestClient(app)
    for method, url in [
        ("GET", "/v1/orgs"),
        ("POST", "/v1/orgs"),
        ("GET", f"/v1/orgs/{ORG_ID}/members"),
    ]:
        r = c.request(method, url)
        assert r.status_code == 401
        assert r.json()["error"]["code"] == "unauthorized"


@pytest.mark.parametrize("role", ["viewer", "editor"])
def test_403_insufficient_role(client: TestClient, db: FakeDB, role: str) -> None:
    db.my_role = role
    r = client.get(f"/v1/orgs/{ORG_ID}/members")
    assert r.status_code == 403
    assert r.json()["error"]["code"] == "insufficient_role"


def test_403_not_a_member(client: TestClient, db: FakeDB) -> None:
    db.my_role = None
    r = client.delete(f"/v1/orgs/{ORG_ID}/members/{OTHER_ID}")
    assert r.status_code == 403
    assert r.json()["error"]["code"] == "not_a_member"


def test_path_wins_and_header_must_match(client: TestClient) -> None:
    ok = client.get(f"/v1/orgs/{ORG_ID}/members", headers={"X-Org-Id": ORG_ID})
    assert ok.status_code == 200
    bad = client.get(f"/v1/orgs/{ORG_ID}/members", headers={"X-Org-Id": str(uuid4())})
    assert bad.status_code == 400
    assert bad.json()["error"]["code"] == "org_mismatch"
    assert client.get("/v1/orgs/not-a-uuid/members").json()["error"]["code"] == "invalid_org_id"


# --- orgs ----------------------------------------------------------------------------------
def test_list_my_orgs(client: TestClient) -> None:
    r = client.get("/v1/orgs")
    assert r.status_code == 200
    assert r.json() == [{**ORG_ROW, "role": "owner"}]


def test_create_org_calls_rpc_normalized(client: TestClient, db: FakeDB) -> None:
    r = client.post("/v1/orgs", json={"name": "  Acme ", "slug": " Acme "})
    assert r.status_code == 201
    assert r.json()["slug"] == "acme"
    assert db.rpc_calls == [("create_organization", {"p_name": "Acme", "p_slug": "acme"})]


def test_create_org_slug_taken_409(client: TestClient, db: FakeDB) -> None:
    db.errors["rpc"] = err("23505")
    r = client.post("/v1/orgs", json={"name": "Acme", "slug": "acme"})
    assert r.status_code == 409
    assert r.json()["error"]["code"] == "slug_taken"


@pytest.mark.parametrize(
    "body",
    [
        {"name": "", "slug": "acme"},
        {"name": "x" * 121, "slug": "acme"},
        {"name": "Acme", "slug": "a"},
        {"name": "Acme", "slug": "-acme"},
        {"name": "Acme", "slug": "ac me"},
        {"name": "Acme", "slug": "acme", "plan": "pro"},
        {"slug": "acme"},
    ],
)
def test_create_org_validation_422(client: TestClient, body: dict[str, Any]) -> None:
    r = client.post("/v1/orgs", json=body)
    assert r.status_code == 422
    assert r.json()["error"]["code"] == "validation_error"


# --- members -------------------------------------------------------------------------------
def test_list_members(client: TestClient) -> None:
    r = client.get(f"/v1/orgs/{ORG_ID}/members")
    assert r.status_code == 200
    assert [m["user_id"] for m in r.json()] == [OTHER_ID]


def test_add_member_by_user_id(client: TestClient) -> None:
    uid = str(uuid4())
    r = client.post(f"/v1/orgs/{ORG_ID}/members", json={"user_id": uid, "role": "editor"})
    assert r.status_code == 201
    assert r.json()["user_id"] == uid
    assert r.json()["role"] == "editor"


def test_add_member_default_role_viewer(client: TestClient) -> None:
    r = client.post(f"/v1/orgs/{ORG_ID}/members", json={"user_id": str(uuid4())})
    assert r.json()["role"] == "viewer"


def test_add_member_unknown_user_404(client: TestClient, db: FakeDB) -> None:
    db.errors["insert"] = err("23503")
    r = client.post(f"/v1/orgs/{ORG_ID}/members", json={"user_id": str(uuid4())})
    assert r.status_code == 404
    assert r.json()["error"]["code"] == "not_found"


def test_add_member_duplicate_409(client: TestClient, db: FakeDB) -> None:
    db.errors["insert"] = err("23505")
    r = client.post(f"/v1/orgs/{ORG_ID}/members", json={"user_id": OTHER_ID})
    assert r.status_code == 409
    assert r.json()["error"]["code"] == "already_member"


def test_add_member_rls_denied_403(client: TestClient, db: FakeDB) -> None:
    db.errors["insert"] = err("42501", status=403)
    r = client.post(f"/v1/orgs/{ORG_ID}/members", json={"user_id": OTHER_ID, "role": "owner"})
    assert r.status_code == 403


def test_add_member_by_email_not_available(client: TestClient) -> None:
    r = client.post(f"/v1/orgs/{ORG_ID}/members", json={"email": "a@b.co"})
    assert r.status_code == 501
    assert r.json()["error"]["code"] == "email_lookup_unavailable"


@pytest.mark.parametrize(
    "body",
    [
        {},
        {"user_id": str(uuid4()), "email": "a@b.co"},
        {"user_id": "nope"},
        {"email": "no-es-email"},
        {"user_id": str(uuid4()), "role": "superuser"},
    ],
)
def test_add_member_validation_422(client: TestClient, body: dict[str, Any]) -> None:
    assert client.post(f"/v1/orgs/{ORG_ID}/members", json=body).status_code == 422


def test_change_role(client: TestClient) -> None:
    r = client.patch(f"/v1/orgs/{ORG_ID}/members/{OTHER_ID}", json={"role": "editor"})
    assert r.status_code == 200
    assert r.json()["role"] == "editor"


def test_change_role_invalid_422(client: TestClient) -> None:
    r = client.patch(f"/v1/orgs/{ORG_ID}/members/{OTHER_ID}", json={"role": "root"})
    assert r.status_code == 422


def test_change_role_missing_member_404(client: TestClient) -> None:
    r = client.patch(f"/v1/orgs/{ORG_ID}/members/{uuid4()}", json={"role": "editor"})
    assert r.status_code == 404
    assert r.json()["error"]["code"] == "member_not_found"


def test_change_role_blocked_by_rls_403(client: TestClient, db: FakeDB) -> None:
    db.blocked_by_rls = True
    r = client.patch(f"/v1/orgs/{ORG_ID}/members/{OTHER_ID}", json={"role": "editor"})
    assert r.status_code == 403


def test_change_role_last_owner_409(client: TestClient, db: FakeDB) -> None:
    db.errors["update"] = err("P0001", "last_owner")
    r = client.patch(f"/v1/orgs/{ORG_ID}/members/{OTHER_ID}", json={"role": "viewer"})
    assert r.status_code == 409
    assert r.json()["error"]["code"] == "last_owner"


def test_delete_member(client: TestClient, db: FakeDB) -> None:
    r = client.delete(f"/v1/orgs/{ORG_ID}/members/{OTHER_ID}")
    assert r.status_code == 204
    assert OTHER_ID not in db.members


def test_delete_missing_404_and_rls_403(client: TestClient, db: FakeDB) -> None:
    assert client.delete(f"/v1/orgs/{ORG_ID}/members/{uuid4()}").status_code == 404
    db.blocked_by_rls = True
    assert client.delete(f"/v1/orgs/{ORG_ID}/members/{OTHER_ID}").status_code == 403


def test_delete_last_owner_409(client: TestClient, db: FakeDB) -> None:
    db.errors["delete"] = err("P0001", "last_owner")
    r = client.delete(f"/v1/orgs/{ORG_ID}/members/{OTHER_ID}")
    assert r.status_code == 409
    assert r.json()["error"]["code"] == "last_owner"


def test_unknown_db_error_is_502_without_details(client: TestClient, db: FakeDB) -> None:
    db.errors["delete"] = PostgrestError(400, "XX000", "secreto interno", None)
    r = client.delete(f"/v1/orgs/{ORG_ID}/members/{OTHER_ID}")
    assert r.status_code == 502
    assert "secreto" not in r.text


# --- UserDB (PostgREST con respx) ------------------------------------------------------------
@pytest.fixture
def user_db() -> UserDB:
    return UserDB(
        Settings(
            supabase_url="https://p.supabase.co",
            supabase_anon_key="anon",
            supabase_jwt_secret="x" * 40,
        ),
        "user-jwt",
    )


@respx.mock
def test_userdb_rpc_and_error_parsing(user_db: UserDB) -> None:
    asyncio.run(_rpc_and_errors(user_db))


async def _rpc_and_errors(user_db: UserDB) -> None:
    base = "https://p.supabase.co/rest/v1"
    route = respx.post(f"{base}/rpc/create_organization").mock(
        side_effect=[
            httpx.Response(200, json=ORG_ROW),
            httpx.Response(409, json={"code": "23505", "message": "dup", "hint": None}),
            httpx.Response(500, text="boom"),
        ]
    )
    assert await user_db.rpc("create_organization", {"p_name": "a", "p_slug": "aaa"}) == ORG_ROW
    sent = route.calls[0].request
    assert sent.headers["authorization"] == "Bearer user-jwt"
    with pytest.raises(PostgrestError) as ei:
        await user_db.rpc("create_organization", {})
    assert ei.value.code == "23505"
    with pytest.raises(httpx.HTTPStatusError):
        await user_db.rpc("create_organization", {})
    await user_db.aclose()


@respx.mock
def test_userdb_write_methods_ask_representation(user_db: UserDB) -> None:
    asyncio.run(_writes(user_db))


async def _writes(user_db: UserDB) -> None:
    base = "https://p.supabase.co/rest/v1/memberships"
    ins = respx.post(base).mock(return_value=httpx.Response(201, json=[{"a": 1}]))
    upd = respx.patch(base).mock(return_value=httpx.Response(200, json=[{"a": 2}]))
    dele = respx.delete(base).mock(return_value=httpx.Response(200, json=[]))
    assert await user_db.insert("memberships", {"a": 1}) == [{"a": 1}]
    assert await user_db.update("memberships", {"a": "eq.1"}, {"a": 2}) == [{"a": 2}]
    assert await user_db.delete("memberships", {"a": "eq.1"}) == []
    for route in (ins, upd, dele):
        assert route.calls[0].request.headers["prefer"] == "return=representation"
    await user_db.aclose()
