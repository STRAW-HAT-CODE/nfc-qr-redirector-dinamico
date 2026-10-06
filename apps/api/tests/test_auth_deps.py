import json
import time
from collections.abc import Iterator
from typing import Annotated, Any
from uuid import uuid4

import httpx
import jwt
import pytest
import respx
from cryptography.hazmat.primitives.asymmetric import rsa
from fastapi import Depends, FastAPI
from fastapi.testclient import TestClient
from jwt.algorithms import RSAAlgorithm

from app import auth
from app.auth import CurrentUser
from app.core.config import Settings, get_settings
from app.deps import Role, get_current_user, get_db, require_role
from app.errors import register_error_handlers

SUPABASE_URL = "https://proj.supabase.co"
ISSUER = f"{SUPABASE_URL}/auth/v1"
JWKS_URL = f"{ISSUER}/.well-known/jwks.json"
HS_SECRET = "test-secret-with-at-least-32-bytes-long!!"
KID = "kid-1"
USER_ID = str(uuid4())
ORG_ID = str(uuid4())

_KEY = rsa.generate_private_key(public_exponent=65537, key_size=2048)
_OTHER_KEY = rsa.generate_private_key(public_exponent=65537, key_size=2048)


def _jwks() -> dict[str, Any]:
    jwk = json.loads(RSAAlgorithm.to_jwk(_KEY.public_key()))
    return {"keys": [{**jwk, "kid": KID, "alg": "RS256", "use": "sig"}]}


def make_token(
    *,
    key: Any = _KEY,
    alg: str = "RS256",
    exp_delta: int = 3600,
    aud: str = "authenticated",
    iss: str = ISSUER,
    kid: str | None = KID,
) -> str:
    claims = {
        "sub": USER_ID,
        "email": "u@example.com",
        "role": "authenticated",
        "aud": aud,
        "iss": iss,
        "exp": int(time.time()) + exp_delta,
    }
    headers = {"kid": kid} if kid and alg != "HS256" else None
    return jwt.encode(claims, key, algorithm=alg, headers=headers)


class FakeDB:
    def __init__(self, role: str | None) -> None:
        self.role = role
        self.calls: list[tuple[str, dict[str, Any]]] = []

    async def rpc(self, fn: str, args: dict[str, Any]) -> Any:
        self.calls.append((fn, args))
        return self.role


@pytest.fixture
def settings() -> Settings:
    return Settings(
        supabase_url=SUPABASE_URL,
        supabase_anon_key="anon",
        supabase_jwt_secret=HS_SECRET,
    )


@pytest.fixture
def fake_db() -> FakeDB:
    return FakeDB("viewer")


@pytest.fixture
def client(settings: Settings, fake_db: FakeDB) -> Iterator[TestClient]:
    auth.clear_jwks_cache()
    app = FastAPI()
    register_error_handlers(app)

    @app.get("/me")
    async def me(user: Annotated[CurrentUser, Depends(get_current_user)]) -> dict[str, str | None]:
        return {"id": user.id, "email": user.email, "role": user.role}

    for role in Role:

        def make(r: Role) -> None:
            @app.get(f"/needs/{r.name}")
            async def needs(
                user: Annotated[CurrentUser, Depends(require_role(r))],
            ) -> dict[str, str]:
                return {"id": user.id}

        make(role)

    app.dependency_overrides[get_settings] = lambda: settings
    app.dependency_overrides[get_db] = lambda: fake_db
    with respx.mock(assert_all_called=False) as mock:
        mock.get(JWKS_URL).mock(return_value=httpx.Response(200, json=_jwks()))
        yield TestClient(app)


def bearer(token: str) -> dict[str, str]:
    return {"Authorization": f"Bearer {token}"}


# --- 401 -------------------------------------------------------------------
def test_no_token_401(client: TestClient) -> None:
    r = client.get("/me")
    assert r.status_code == 401
    assert r.json()["error"]["code"] == "unauthorized"


def test_non_bearer_401(client: TestClient) -> None:
    assert client.get("/me", headers={"Authorization": "Basic abc"}).status_code == 401


@pytest.mark.parametrize(
    "kwargs",
    [
        {"exp_delta": -10},
        {"aud": "anon"},
        {"iss": "https://evil.example/auth/v1"},
        {"key": _OTHER_KEY},
    ],
    ids=["expired", "bad-aud", "bad-iss", "bad-signature"],
)
def test_invalid_jwks_token_401(client: TestClient, kwargs: dict[str, Any]) -> None:
    r = client.get("/me", headers=bearer(make_token(**kwargs)))
    assert r.status_code == 401
    assert r.json()["error"]["code"] == "invalid_token"


def test_garbage_token_401(client: TestClient) -> None:
    assert client.get("/me", headers=bearer("not.a.jwt")).status_code == 401


def test_unknown_kid_401(client: TestClient) -> None:
    assert client.get("/me", headers=bearer(make_token(kid="other"))).status_code == 401


def test_alg_none_rejected(client: TestClient) -> None:
    token = jwt.encode({"sub": USER_ID, "aud": "authenticated", "iss": ISSUER}, None, "none")
    assert client.get("/me", headers=bearer(token)).status_code == 401


def test_valid_jwks_token(client: TestClient) -> None:
    r = client.get("/me", headers=bearer(make_token()))
    assert r.status_code == 200
    assert r.json() == {"id": USER_ID, "email": "u@example.com", "role": "authenticated"}


# --- HS256 fallback ----------------------------------------------------------
def test_hs256_valid(client: TestClient) -> None:
    token = make_token(key=HS_SECRET, alg="HS256")
    assert client.get("/me", headers=bearer(token)).status_code == 200


def test_hs256_wrong_secret(client: TestClient) -> None:
    token = make_token(key="x" * 40, alg="HS256")
    assert client.get("/me", headers=bearer(token)).status_code == 401


def test_hs256_expired(client: TestClient) -> None:
    token = make_token(key=HS_SECRET, alg="HS256", exp_delta=-5)
    assert client.get("/me", headers=bearer(token)).status_code == 401


# --- JWKS cache --------------------------------------------------------------
def test_jwks_is_cached(client: TestClient) -> None:
    for _ in range(3):
        assert client.get("/me", headers=bearer(make_token())).status_code == 200


def test_jwks_fetch_count(settings: Settings) -> None:
    import asyncio

    auth.clear_jwks_cache()
    with respx.mock() as mock:
        route = mock.get(JWKS_URL).mock(return_value=httpx.Response(200, json=_jwks()))
        for _ in range(3):
            asyncio.run(auth.verify_token(make_token(), settings))
        assert route.call_count == 1


def test_jwks_unreachable_401(settings: Settings) -> None:
    import asyncio

    auth.clear_jwks_cache()
    with respx.mock() as mock:
        mock.get(JWKS_URL).mock(return_value=httpx.Response(500))
        with pytest.raises(auth.InvalidTokenError):
            asyncio.run(auth.verify_token(make_token(), settings))


# --- 400 / 403 / 200 ---------------------------------------------------------
def headers(org: str | None = ORG_ID) -> dict[str, str]:
    h = bearer(make_token())
    if org is not None:
        h["X-Org-Id"] = org
    return h


@pytest.mark.parametrize("org", [None, "not-a-uuid", ""])
def test_bad_org_id_400(client: TestClient, org: str | None) -> None:
    r = client.get("/needs/viewer", headers=headers(org))
    assert r.status_code == 400
    assert r.json()["error"]["code"] == "invalid_org_id"


def test_no_token_beats_org_check(client: TestClient) -> None:
    assert client.get("/needs/viewer", headers={"X-Org-Id": ORG_ID}).status_code == 401


def test_not_member_403(client: TestClient, fake_db: FakeDB) -> None:
    fake_db.role = None
    r = client.get("/needs/viewer", headers=headers())
    assert r.status_code == 403
    assert r.json()["error"]["code"] == "not_a_member"


@pytest.mark.parametrize("have", list(Role))
@pytest.mark.parametrize("need", list(Role))
def test_role_matrix(client: TestClient, fake_db: FakeDB, have: Role, need: Role) -> None:
    fake_db.role = have.name
    r = client.get(f"/needs/{need.name}", headers=headers())
    if have >= need:
        assert r.status_code == 200
        assert r.json() == {"id": USER_ID}
    else:
        assert r.status_code == 403
        assert r.json()["error"]["code"] == "insufficient_role"


def test_membership_query_scoped(client: TestClient, fake_db: FakeDB) -> None:
    client.get("/needs/viewer", headers=headers())
    fn, args = fake_db.calls[0]
    assert fn == "my_effective_role"
    assert args == {"p_org_id": ORG_ID}


# --- db.py y errores ---------------------------------------------------------
def test_userdb_uses_user_jwt(settings: Settings) -> None:
    import asyncio

    from app.db import UserDB

    async def run() -> httpx.Request:
        with respx.mock() as mock:
            route = mock.get(f"{SUPABASE_URL}/rest/v1/memberships").mock(
                return_value=httpx.Response(200, json=[{"role": "admin"}])
            )
            db = UserDB(settings, "user-jwt")
            rows = await db.select("memberships", {"select": "role"})
            await db.aclose()
            assert rows == [{"role": "admin"}]
            return route.calls[0].request

    req = asyncio.run(run())
    assert req.headers["authorization"] == "Bearer user-jwt"
    assert req.headers["apikey"] == "anon"


def test_validation_error_format(client: TestClient) -> None:
    from app.main import app

    r = TestClient(app).get("/healthz", params={})
    assert r.status_code == 200
    r404 = TestClient(app).get("/nope")
    assert r404.status_code == 404
    assert r404.json()["error"]["code"] == "not_found"
