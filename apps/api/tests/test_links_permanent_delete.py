"""DELETE /v1/links/{id}/permanent (DQR-T063): borrado definitivo + logo en Storage."""

from collections.abc import Iterator
from typing import Any

import httpx
import pytest
import respx
from fastapi.testclient import TestClient

from app.auth import CurrentUser
from app.core.config import Settings, get_settings
from app.deps import get_current_user, get_db
from app.main import app
from tests.test_links import BASE, ORG, OTHER_ORG, FakeDB, H, create

SUPA = "https://x.supabase.co"


class PermDB(FakeDB):
    def __init__(self, role: str | None) -> None:
        super().__init__(role)
        self.designs: list[dict[str, Any]] = []
        self.deleted: list[dict[str, str]] = []

    async def select(self, table: str, params: dict[str, str]) -> list[dict[str, Any]]:
        if table == "qr_designs":
            return self._filter(self.designs, params)
        return await super().select(table, params)

    async def delete(self, table: str, params: dict[str, str]) -> list[dict[str, Any]]:
        assert table == "dynamic_links"
        if not self._can("admin"):
            return []  # RLS: sin filas
        rows = self._filter(self.links, params)
        for r in rows:
            self.links.remove(r)
        self.deleted.append(params)
        return rows


@pytest.fixture
def pdb() -> PermDB:
    return PermDB("admin")


@pytest.fixture
def client(pdb: PermDB) -> Iterator[TestClient]:
    app.dependency_overrides[get_settings] = lambda: Settings(
        public_redirect_base_url=BASE, supabase_url=SUPA, supabase_anon_key="anon"
    )
    app.dependency_overrides[get_db] = lambda: pdb
    app.dependency_overrides[get_current_user] = lambda: CurrentUser(
        id="u", email=None, role="authenticated", raw_token="tok"
    )
    yield TestClient(app)
    app.dependency_overrides.clear()


def test_admin_deletes_204(pdb: PermDB, client: TestClient) -> None:
    link = create(client)
    r = client.delete(f"/v1/links/{link['id']}/permanent", headers=H)
    assert r.status_code == 204
    assert pdb.links == []
    assert pdb.deleted[0]["org_id"] == f"eq.{ORG}"
    assert client.get(f"/v1/links/{link['id']}", headers=H).status_code == 404


def test_editor_403(pdb: PermDB, client: TestClient) -> None:
    link = create(client)
    pdb.role = "editor"
    r = client.delete(f"/v1/links/{link['id']}/permanent", headers=H)
    assert r.status_code == 403
    assert len(pdb.links) == 1


def test_missing_404(client: TestClient) -> None:
    r = client.delete("/v1/links/00000000-0000-0000-0000-000000000000/permanent", headers=H)
    assert r.status_code == 404
    assert r.json()["error"]["code"] == "link_not_found"


def test_other_org_404(pdb: PermDB, client: TestClient) -> None:
    link = create(client)
    pdb.links[0]["org_id"] = OTHER_ORG
    r = client.delete(f"/v1/links/{link['id']}/permanent", headers=H)
    assert r.status_code == 404
    assert len(pdb.links) == 1


def _with_logo(pdb: PermDB, link: dict[str, Any]) -> str:
    path = f"{ORG}/logo.png"
    pdb.designs.append({"link_id": link["id"], "org_id": ORG, "logo_path": path})
    return path


@respx.mock
def test_deletes_logo_from_storage(pdb: PermDB, client: TestClient) -> None:
    link = create(client)
    path = _with_logo(pdb, link)
    route = respx.delete(f"{SUPA}/storage/v1/object/logos/{path}").mock(
        return_value=httpx.Response(200, json={})
    )
    assert client.delete(f"/v1/links/{link['id']}/permanent", headers=H).status_code == 204
    assert route.called
    assert route.calls[0].request.headers["authorization"] == "Bearer tok"
    assert pdb.links == []


@respx.mock
@pytest.mark.parametrize("failure", [httpx.Response(500), httpx.ConnectError("boom")])
def test_storage_error_does_not_block(
    pdb: PermDB, client: TestClient, failure: httpx.Response | Exception
) -> None:
    link = create(client)
    path = _with_logo(pdb, link)
    route = respx.delete(f"{SUPA}/storage/v1/object/logos/{path}")
    if isinstance(failure, Exception):
        route.mock(side_effect=failure)
    else:
        route.mock(return_value=failure)
    assert client.delete(f"/v1/links/{link['id']}/permanent", headers=H).status_code == 204
    assert pdb.links == []


@respx.mock
def test_no_logo_no_storage_call(pdb: PermDB, client: TestClient) -> None:
    link = create(client)
    pdb.designs.append({"link_id": link["id"], "org_id": ORG, "logo_path": None})
    assert client.delete(f"/v1/links/{link['id']}/permanent", headers=H).status_code == 204
    assert len(respx.calls) == 0


def test_archive_unchanged(pdb: PermDB, client: TestClient) -> None:
    link = create(client)
    r = client.delete(f"/v1/links/{link['id']}", headers=H)
    assert r.status_code == 200
    assert r.json()["status"] == "archived"
