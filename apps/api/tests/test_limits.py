"""Límites de plan (DQR-T053): P0001 + hint → 409 con mensaje legible."""

from collections.abc import Callable, Iterator

import pytest
from fastapi.testclient import TestClient

from app.auth import CurrentUser
from app.db import PostgrestError
from app.deps import get_current_user, get_db
from app.errors import ApiError
from app.main import app
from app.services import links, nfc, orgs
from app.services.limits import plan_limit_error
from tests.test_orgs import ORG_ID, OTHER_ID, USER_ID, FakeDB

PLAN_MSG = "Has alcanzado el límite de tu plan: máximo 10 enlaces"
ORG_MSG = "Has alcanzado el máximo de 5 organizaciones propias"


def pg(code: str, hint: str | None, message: str = "msg") -> PostgrestError:
    return PostgrestError(400, code, message, hint)


# --- plan_limit_error -------------------------------------------------------------------
def test_plan_limit_reached_409_with_db_message() -> None:
    e = plan_limit_error(pg("P0001", "plan_limit_reached", PLAN_MSG))
    assert e is not None
    assert (e.status_code, e.code, e.detail) == (409, "plan_limit_reached", PLAN_MSG)


def test_org_limit_409() -> None:
    e = plan_limit_error(pg("P0001", "org_limit", ORG_MSG))
    assert e is not None
    assert (e.status_code, e.code, e.detail) == (409, "org_limit_reached", ORG_MSG)


def test_empty_message_uses_fallback() -> None:
    e = plan_limit_error(pg("P0001", "plan_limit_reached", "  "))
    assert e is not None
    assert e.detail == "Has alcanzado el límite de tu plan"


@pytest.mark.parametrize(
    ("code", "hint"),
    [("P0001", "last_owner"), ("P0001", None), ("42501", "plan_limit_reached"), ("23505", None)],
)
def test_other_errors_are_not_limits(code: str, hint: str | None) -> None:
    assert plan_limit_error(pg(code, hint)) is None


# --- integración en los map_db_error existentes ------------------------------------------
MAPPERS: list[Callable[[PostgrestError], ApiError]] = [
    links.map_db_error,
    nfc.map_db_error,
    orgs.map_db_error,
]


@pytest.mark.parametrize("mapper", MAPPERS)
def test_services_map_plan_limit(mapper: Callable[[PostgrestError], ApiError]) -> None:
    e = mapper(pg("P0001", "plan_limit_reached", PLAN_MSG))
    assert (e.status_code, e.code, e.detail) == (409, "plan_limit_reached", PLAN_MSG)


@pytest.mark.parametrize("mapper", MAPPERS)
def test_services_keep_unknown_p0001_as_502(mapper: Callable[[PostgrestError], ApiError]) -> None:
    e = mapper(pg("P0001", "otra_cosa", "detalle interno"))
    assert (e.status_code, e.code) == (502, "upstream_error")


def test_orgs_last_owner_unchanged() -> None:
    assert orgs.map_db_error(pg("P0001", "last_owner")).code == "last_owner"


# --- endpoints ---------------------------------------------------------------------------
@pytest.fixture
def fake() -> FakeDB:
    return FakeDB()


@pytest.fixture
def client(fake: FakeDB) -> Iterator[TestClient]:
    app.dependency_overrides[get_current_user] = lambda: CurrentUser(
        id=USER_ID, email="u@example.com", role="authenticated", raw_token="jwt"
    )
    app.dependency_overrides[get_db] = lambda: fake
    yield TestClient(app)
    app.dependency_overrides.clear()


def test_create_org_over_limit_409(client: TestClient, fake: FakeDB) -> None:
    fake.errors["rpc"] = pg("P0001", "org_limit", ORG_MSG)
    r = client.post("/v1/orgs", json={"name": "Acme", "slug": "acme"})
    assert r.status_code == 409
    assert r.json() == {"error": {"code": "org_limit_reached", "message": ORG_MSG}}


def test_add_member_over_limit_409(client: TestClient, fake: FakeDB) -> None:
    msg = "Has alcanzado el límite de tu plan: máximo 3 miembros"
    fake.errors["insert"] = pg("P0001", "plan_limit_reached", msg)
    r = client.post(f"/v1/orgs/{ORG_ID}/members", json={"user_id": OTHER_ID})
    assert r.status_code == 409
    assert r.json() == {"error": {"code": "plan_limit_reached", "message": msg}}
