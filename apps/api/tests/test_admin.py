"""Tests de /v1/admin, /v1/me y require_role con my_effective_role. Sin red (respx)."""

from collections.abc import Iterator
from typing import Any
from uuid import uuid4

import httpx
import pytest
import respx
from fastapi.testclient import TestClient

from app.auth import CurrentUser
from app.core.config import Settings, get_settings
from app.deps import Role, get_current_user
from app.main import app

BASE = "https://p.supabase.co"
RPC = f"{BASE}/rest/v1/rpc"
ORG = str(uuid4())
LINK = str(uuid4())
NOW = "2026-01-01T00:00:00Z"
ORG_ROW = {
    "id": ORG,
    "name": "Acme",
    "slug": "acme",
    "plan": "pro",
    "status": "active",
    "limits": {"links": 10},
    "created_at": NOW,
}
FORBIDDEN = {"code": "42501", "message": "not platform admin"}


@pytest.fixture
def client() -> Iterator[TestClient]:
    app.dependency_overrides[get_current_user] = lambda: CurrentUser(
        id="u1", email="u@example.com", role="authenticated", raw_token="user-jwt"
    )
    app.dependency_overrides[get_settings] = lambda: Settings(
        supabase_url=BASE, supabase_anon_key="anon", supabase_jwt_secret="s"
    )
    yield TestClient(app)
    app.dependency_overrides.clear()


@pytest.fixture
def mock() -> Iterator[respx.MockRouter]:
    with respx.mock(assert_all_called=False) as m:
        yield m


def rpc(mock: respx.MockRouter, fn: str, status: int = 200, body: Any = None) -> respx.Route:
    return mock.post(f"{RPC}/{fn}").mock(return_value=httpx.Response(status, json=body))


def test_401_without_token() -> None:
    app.dependency_overrides.clear()
    c = TestClient(app)
    for method, url in [
        ("GET", "/v1/me"),
        ("GET", "/v1/admin/orgs"),
        ("GET", "/v1/admin/blocked-domains"),
    ]:
        assert c.request(method, url).status_code == 401


# --- /v1/me --------------------------------------------------------------------------
@pytest.mark.parametrize(("role", "expected"), [("owner", True), (None, False), ("admin", False)])
def test_me(client: TestClient, mock: respx.MockRouter, role: str | None, expected: bool) -> None:
    route = rpc(mock, "my_effective_role", body=role)
    r = client.get("/v1/me")
    assert r.status_code == 200
    assert r.json() == {"user_id": "u1", "email": "u@example.com", "is_platform_admin": expected}
    assert route.calls[0].request.headers["authorization"] == "Bearer user-jwt"


# --- 403 para usuario normal ---------------------------------------------------------
@pytest.mark.parametrize(
    ("method", "url", "fn", "body"),
    [
        ("GET", "/v1/admin/orgs", "admin_list_orgs", None),
        ("PATCH", f"/v1/admin/orgs/{ORG}", "admin_update_org", {"plan": "pro"}),
        ("GET", "/v1/admin/blocked-domains", "admin_list_blocked_domains", None),
        ("POST", "/v1/admin/blocked-domains", "admin_block_domain", {"domain": "evil.com"}),
        ("DELETE", "/v1/admin/blocked-domains", "admin_unblock_domain", {"domain": "evil.com"}),
        ("GET", "/v1/admin/links?slug=abc", "admin_find_link", None),
        ("PATCH", f"/v1/admin/links/{LINK}/status", "admin_set_link_status", {"status": "paused"}),
    ],
)
def test_403_normal_user(
    client: TestClient, mock: respx.MockRouter, method: str, url: str, fn: str, body: Any
) -> None:
    rpc(mock, fn, 403, FORBIDDEN)
    r = client.request(method, url, json=body)
    assert r.status_code == 403
    assert r.json()["error"]["code"] == "not_platform_admin"


# --- happy paths ---------------------------------------------------------------------
def test_list_orgs(client: TestClient, mock: respx.MockRouter) -> None:
    route = rpc(
        mock, "admin_list_orgs", body=[{**ORG_ROW, "members": 3, "links": 5, "scans_30d": 99}]
    )
    r = client.get("/v1/admin/orgs", params={"q": "acm", "limit": 10, "offset": 5})
    assert r.status_code == 200
    assert r.json()[0]["scans_30d"] == 99
    import json

    assert json.loads(route.calls[0].request.content) == {
        "p_q": "acm",
        "p_limit": 10,
        "p_offset": 5,
    }


def test_list_orgs_validates_paging(client: TestClient) -> None:
    assert client.get("/v1/admin/orgs", params={"limit": 0}).status_code == 422
    assert client.get("/v1/admin/orgs", params={"limit": 500}).status_code == 422


def test_update_org(client: TestClient, mock: respx.MockRouter) -> None:
    route = rpc(mock, "admin_update_org", body=ORG_ROW)
    r = client.patch(f"/v1/admin/orgs/{ORG}", json={"status": "suspended", "limits": {"links": 5}})
    assert r.status_code == 200
    assert r.json()["plan"] == "pro"
    import json

    assert json.loads(route.calls[0].request.content) == {
        "p_org_id": ORG,
        "p_plan": None,
        "p_status": "suspended",
        "p_limits": {"links": 5},
    }


@pytest.mark.parametrize("body", [{}, {"plan": None}, {"status": "weird"}, {"x": 1}])
def test_update_org_validation(client: TestClient, body: dict[str, Any]) -> None:
    assert client.patch(f"/v1/admin/orgs/{ORG}", json=body).status_code == 422


def test_update_org_not_found(client: TestClient, mock: respx.MockRouter) -> None:
    rpc(mock, "admin_update_org", 404, {"code": "P0002", "message": "x"})
    assert client.patch(f"/v1/admin/orgs/{ORG}", json={"plan": "pro"}).status_code == 404


def test_blocked_domains_crud(client: TestClient, mock: respx.MockRouter) -> None:
    rpc(mock, "admin_list_blocked_domains", body=[{"domain": "evil.com", "created_at": NOW}])
    assert client.get("/v1/admin/blocked-domains").json() == [
        {"domain": "evil.com", "created_at": "2026-01-01T00:00:00Z"}
    ]
    block = rpc(mock, "admin_block_domain", 200, None)
    assert (
        client.post("/v1/admin/blocked-domains", json={"domain": " Evil.COM "}).status_code == 204
    )
    assert b"Evil.COM" in block.calls[0].request.content
    rpc(mock, "admin_unblock_domain", 200, None)
    assert (
        client.request(
            "DELETE", "/v1/admin/blocked-domains", json={"domain": "evil.com"}
        ).status_code
        == 204
    )


def test_block_domain_invalid_is_422(client: TestClient, mock: respx.MockRouter) -> None:
    rpc(mock, "admin_block_domain", 400, {"code": "23514", "message": "check"})
    assert client.post("/v1/admin/blocked-domains", json={"domain": "no_valid"}).status_code == 422


def test_find_link_and_set_status(client: TestClient, mock: respx.MockRouter) -> None:
    row = {
        "id": LINK,
        "org_id": ORG,
        "org_name": "Acme",
        "slug": "Ab3dE01",
        "name": "n",
        "destination_url": "https://x.com",
        "status": "active",
        "created_at": NOW,
    }
    rpc(mock, "admin_find_link", body=[row])
    assert client.get("/v1/admin/links", params={"slug": "Ab3dE01"}).json()[0]["org_name"] == "Acme"
    assert client.get("/v1/admin/links").status_code == 422
    rpc(mock, "admin_set_link_status", body={**row, "status": "paused"})
    r = client.patch(f"/v1/admin/links/{LINK}/status", json={"status": "paused"})
    assert r.status_code == 200
    assert r.json()["status"] == "paused"
    assert client.patch(f"/v1/admin/links/{LINK}/status", json={"status": "x"}).status_code == 422


def test_upstream_failure_is_502(client: TestClient, mock: respx.MockRouter) -> None:
    rpc(mock, "admin_list_orgs", 500, {})
    assert client.get("/v1/admin/orgs").status_code == 502
    mock.post(f"{RPC}/admin_find_link").mock(side_effect=httpx.ConnectError("boom"))
    assert client.get("/v1/admin/links", params={"slug": "a"}).status_code == 502


# --- require_role con my_effective_role ----------------------------------------------
def test_platform_admin_enters_as_owner(client: TestClient, mock: respx.MockRouter) -> None:
    """Un platform admin (RPC => 'owner') pasa un endpoint admin de org sin ser miembro."""
    role = rpc(mock, "my_effective_role", body="owner")
    mock.get(f"{BASE}/rest/v1/memberships").mock(return_value=httpx.Response(200, json=[]))
    r = client.get(f"/v1/orgs/{ORG}/members")
    assert r.status_code == 200
    assert role.called


def test_non_member_still_403(client: TestClient, mock: respx.MockRouter) -> None:
    rpc(mock, "my_effective_role", body=None)
    r = client.get(f"/v1/orgs/{ORG}/members")
    assert r.status_code == 403
    assert r.json()["error"]["code"] == "not_a_member"


@pytest.mark.parametrize("have", list(Role))
def test_role_from_rpc(client: TestClient, mock: respx.MockRouter, have: Role) -> None:
    rpc(mock, "my_effective_role", body=have.name)
    mock.get(f"{BASE}/rest/v1/memberships").mock(return_value=httpx.Response(200, json=[]))
    r = client.get(f"/v1/orgs/{ORG}/members")
    assert r.status_code == (200 if have >= Role.admin else 403)


def test_role_rpc_error_is_502(client: TestClient, mock: respx.MockRouter) -> None:
    rpc(mock, "my_effective_role", 404, {"code": "PGRST202", "message": "no fn"})
    assert client.get(f"/v1/orgs/{ORG}/members").status_code == 502
