"""DQR-T024 · huecos de cobertura de S1 (DQR-00 a DQR-05). Solo tests, sin cambios de código.

- DQR-01: toda ruta /v1 exige token (401 sin token y con token inválido); una ruta nueva sin
  autenticar rompe estos tests y obliga a declararla pública a propósito.
- DQR-00: `.env.example` cubre la configuración; `.env` está ignorado; la CI ejecuta las
  comprobaciones que promete el módulo.
- DQR-05: la guía de grabado NFC cubre iOS y Android.
- Errores de la capa de métricas (400/403/502) que no tenían test.
"""

import asyncio
import re
from collections.abc import Iterator
from pathlib import Path
from typing import Any
from uuid import uuid4

import httpx
import pytest
from fastapi.routing import APIRoute
from fastapi.testclient import TestClient

from app.core.config import Settings
from app.db import PostgrestError
from app.errors import ApiError
from app.main import app
from app.services.stats import StatsService

ROOT = Path(__file__).resolve().parents[3]

# Rutas públicas por diseño (no /v1). Una ruta pública nueva debe añadirse aquí a propósito.
PUBLIC_ROUTES = {
    ("GET", "/healthz"),
    ("GET", "/r/{slug}"),
    ("GET", "/r/{slug}/"),
}


def _iter_api_routes() -> Iterator[APIRoute]:
    """Todas las APIRoute de la app, incluidas las de routers anidados (include_router)."""
    for r in app.routes:
        if isinstance(r, APIRoute):
            yield r
        for sub in getattr(getattr(r, "original_router", None), "routes", []):
            if isinstance(sub, APIRoute):
                yield sub


def _api_routes() -> list[tuple[str, str]]:
    out: list[tuple[str, str]] = []
    for r in _iter_api_routes():
        for m in sorted(r.methods - {"HEAD", "OPTIONS"}):
            out.append((m, r.path))
    return out


def _fill(path: str) -> str:
    path = path.replace("{fmt}", "png")
    return re.sub(r"\{[^}]+\}", lambda _: str(uuid4()), path)


V1_ROUTES = [(m, p) for m, p in _api_routes() if p.startswith("/v1/")]


def test_route_inventory_is_not_empty_and_public_routes_are_declared() -> None:
    assert len(V1_ROUTES) >= 25  # orgs, links, nfc, qr, stats, admin, me
    others = {(m, p) for m, p in _api_routes() if not p.startswith("/v1/")}
    assert others == PUBLIC_ROUTES, f"rutas públicas no declaradas: {others ^ PUBLIC_ROUTES}"


@pytest.mark.parametrize(("method", "path"), V1_ROUTES, ids=[f"{m} {p}" for m, p in V1_ROUTES])
@pytest.mark.parametrize("auth", [None, "Bearer garbage", "Basic abc", "Bearer "], ids=str)
def test_every_v1_route_requires_a_valid_token(method: str, path: str, auth: str | None) -> None:
    headers = {"Authorization": auth} if auth is not None else {}
    kwargs: dict[str, Any] = {} if method in {"GET", "DELETE"} else {"json": {}}
    r = TestClient(app).request(method, _fill(path), headers=headers, **kwargs)
    assert r.status_code == 401, (method, path, auth, r.status_code, r.text[:120])
    assert r.json()["error"]["code"] in {"unauthorized", "invalid_token"}


# ---------------------------------------------------------------- DQR-00: entorno y CI


def _env_example_keys() -> set[str]:
    text = (ROOT / ".env.example").read_text()
    return set(re.findall(r"^#?\s*([A-Z][A-Z0-9_]+)=", text, flags=re.M))


def test_env_example_has_required_variables() -> None:
    required = {
        "SUPABASE_URL",
        "SUPABASE_ANON_KEY",
        "SUPABASE_SERVICE_ROLE_KEY",
        "SUPABASE_JWT_SECRET",
        "PUBLIC_REDIRECT_BASE_URL",
        "IP_HASH_SALT",
        "TRUSTED_PROXY_HOPS",
        "NEXT_PUBLIC_SUPABASE_URL",
        "NEXT_PUBLIC_SUPABASE_ANON_KEY",
        "NEXT_PUBLIC_API_URL",
    }
    assert required <= _env_example_keys()


@pytest.mark.xfail(
    strict=True,
    reason="Hueco conocido (DQR-00): RATE_LIMIT_* de T050 no están en .env.example ni en docs/07. "
    "Al documentarlas este test pasa y strict=True obliga a quitar el xfail.",
)
def test_every_setting_is_documented_somewhere() -> None:
    """Cada variable de Settings figura en .env.example o en docs/07-deploy.md / el runbook."""
    docs = "\n".join(
        (ROOT / p).read_text()
        for p in ("docs/07-deploy.md", "docs/runbook.md", "docs/06-seguridad.md")
    )
    keys = _env_example_keys()
    injected = {"VERCEL_GIT_COMMIT_SHA"}  # lo inyecta Vercel
    missing = [
        name
        for name in (f.upper() for f in Settings.model_fields)
        if name not in injected and name not in keys and name not in docs
    ]
    assert not missing, f"variables sin documentar: {missing}"


def test_web_env_vars_are_in_env_example() -> None:
    web = ROOT / "apps" / "web"
    used: set[str] = set()
    for pattern in ("*.ts", "*.tsx", "*.mjs"):
        for f in web.rglob(pattern):
            if any(part in {"node_modules", ".next", "test-results"} for part in f.parts):
                continue
            used |= set(re.findall(r"process\.env\.([A-Z][A-Z0-9_]+)", f.read_text()))
    used -= {"NODE_ENV", "CI", "NEXT_RUNTIME"}
    assert used, "no se encontraron variables de entorno en apps/web"
    assert used <= _env_example_keys(), f"faltan en .env.example: {used - _env_example_keys()}"


def test_dotenv_is_gitignored_but_example_is_not() -> None:
    lines = [ln.strip() for ln in (ROOT / ".gitignore").read_text().splitlines()]
    assert ".env" in lines
    assert "!.env.example" in lines
    assert (ROOT / ".env.example").is_file()


def test_ci_runs_the_checks_promised_by_dqr_00() -> None:
    ci = (ROOT / ".github" / "workflows" / "ci.yml").read_text()
    for step in (
        "ruff check",
        "ruff format --check",
        "mypy app",
        "uv run pytest",
        "pnpm lint",
        "pnpm test",
        "pnpm build",
        "supabase db lint --fail-on error",
    ):
        assert step in ci, f"la CI no ejecuta: {step}"
    assert "supabase/tests" in ci  # los tests SQL corren en CI


# ---------------------------------------------------------------- DQR-05: guía NFC y docs


def test_nfc_guide_covers_ios_android_and_ntag213_limit() -> None:
    guide = (ROOT / "docs" / "nfc-guia.md").read_text()
    assert re.search(r"^###\s+Android", guide, re.M)
    assert re.search(r"^###\s+iPhone", guide, re.M)
    assert "NTAG213" in guide and "137" in guide
    assert "?c=n&t=" in guide  # la URL que se graba lleva canal y tag


def test_canva_doc_lists_real_template_sizes() -> None:
    doc = (ROOT / "docs" / "canva.md").read_text()
    for dims in ("56×56", "105×148", "210×297"):
        assert dims in doc


# ---------------------------------------------------------------- métricas: mapeo de errores


class _FailingDB:
    def __init__(self, exc: Exception) -> None:
        self.exc = exc

    async def rpc(self, *_: Any, **__: Any) -> Any:
        raise self.exc

    async def select(self, *_: Any, **__: Any) -> Any:
        raise self.exc


def _stats_error(exc: Exception) -> ApiError:
    from datetime import date

    svc = StatsService(_FailingDB(exc))  # type: ignore[arg-type]
    with pytest.raises(ApiError) as info:
        asyncio.run(
            svc.stats(
                group=__import__("app.schemas.stats", fromlist=["x"]).StatsGroup.day,
                frm=date(2026, 10, 1),
                to=date(2026, 10, 2),
                org_id=uuid4(),
            )
        )
    return info.value


@pytest.mark.parametrize(
    ("exc", "status", "code"),
    [
        (PostgrestError(400, "22023", "bad range", None), 422, "invalid_range"),
        (PostgrestError(403, "42501", "rls", None), 403, "insufficient_role"),
        (PostgrestError(500, "XX000", "boom internals", None), 502, "upstream_error"),
        (httpx.ConnectError("down"), 502, "upstream_error"),
    ],
    ids=["22023", "42501", "otro", "red"],
)
def test_stats_service_maps_db_errors(exc: Exception, status: int, code: str) -> None:
    e = _stats_error(exc)
    assert (e.status_code, e.code) == (status, code)
    assert "boom" not in str(e.detail)  # no se filtran detalles internos
