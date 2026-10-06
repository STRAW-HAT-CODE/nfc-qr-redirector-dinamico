"""Tests de /v1/links/{id}/design y /qr.{png,svg,pdf} sin red: respx para PostgREST y Storage."""

import io
import json
from collections.abc import Iterator
from typing import Any
from uuid import uuid4

import httpx
import pypdfium2 as pdfium
import pytest
import respx
from fastapi.testclient import TestClient
from PIL import Image

from app.auth import CurrentUser
from app.core.config import Settings, get_settings
from app.deps import get_current_user
from app.main import app
from tests.test_qr_render import _raster_svg, decode, decode_png

SB = "https://proj.supabase.co"
ORG = str(uuid4())
USER = str(uuid4())
LINK = str(uuid4())
SLUG = "aB3dE9x"
BASE = "https://go.example.com"
URL = f"{BASE}/r/{SLUG}?c=q"
H = {"X-Org-Id": ORG}
RANK = {"viewer": 1, "editor": 2, "admin": 3, "owner": 4}


class Backend:
    """PostgREST + Storage simulados con respx; aplica las reglas de rol de las policies."""

    def __init__(self, role: str | None) -> None:
        self.role = role
        self.design: dict[str, Any] | None = None
        self.objects: dict[str, bytes] = {}
        self.auth_seen: set[str] = set()
        self.fail_db_write = False
        self.deny_storage = False
        self.limit_hit = False

    def can(self, role: str) -> bool:
        return self.role is not None and RANK[self.role] >= RANK[role]

    def _auth(self, req: httpx.Request) -> None:
        self.auth_seen.add(req.headers["authorization"])

    def memberships(self, req: httpx.Request) -> httpx.Response:
        self._auth(req)
        return httpx.Response(200, json=self.role)

    def links(self, req: httpx.Request) -> httpx.Response:
        self._auth(req)
        ok = req.url.params["id"] == f"eq.{LINK}" and req.url.params["org_id"] == f"eq.{ORG}"
        return httpx.Response(
            200, json=[{"id": LINK, "slug": SLUG}] if ok and self.can("viewer") else []
        )

    def designs(self, req: httpx.Request) -> httpx.Response:
        self._auth(req)
        if req.method == "GET":
            return httpx.Response(200, json=[self.design] if self.design else [])
        if not self.can("editor"):
            return httpx.Response(403, json={"code": "42501", "message": "rls"})
        if self.limit_hit:
            return httpx.Response(
                400,
                json={"code": "P0001", "message": "Límite de logos", "hint": "plan_limit_reached"},
            )
        if self.fail_db_write:
            return httpx.Response(400, json={"code": "23514", "message": "x"})
        body = json.loads(req.content)
        if req.method == "POST":
            assert req.url.params["on_conflict"] == "link_id"
            assert "merge-duplicates" in req.headers["prefer"]
            row = {
                "link_id": LINK,
                "org_id": ORG,
                "fg": "#000000",
                "bg": "#FFFFFF",
                "ecc_level": "M",
                "style": {},
                "logo_path": None,
                "frame": "none",
                **(self.design or {}),
                **body,
            }
        else:  # PATCH
            row = {**(self.design or {}), **body}
        if row.get("logo_path") and row["ecc_level"] != "H":
            return httpx.Response(400, json={"code": "23514", "message": "logo_ecc_check"})
        row["updated_at"] = "2026-01-01T00:00:00+00:00"
        self.design = row
        return httpx.Response(200, json=[row])

    def storage(self, req: httpx.Request) -> httpx.Response:
        self._auth(req)
        path = req.url.path.split("/storage/v1/object/", 1)[1]
        if req.method == "POST":
            if not self.can("editor") or self.deny_storage:
                return httpx.Response(403, json={"error": "Unauthorized"})
            assert req.headers["content-type"] == "image/png"
            key = path.removeprefix("logos/")
            self.objects[key] = req.content
            return httpx.Response(200, json={"Key": path})
        if req.method == "DELETE":
            self.objects.pop(path.removeprefix("logos/"), None)
            return httpx.Response(200, json={})
        key = path.removeprefix("authenticated/logos/")
        if key in self.objects:
            return httpx.Response(200, content=self.objects[key])
        return httpx.Response(404, json={})


@pytest.fixture
def make(monkeypatch: pytest.MonkeyPatch) -> Iterator[Any]:
    app.dependency_overrides[get_settings] = lambda: Settings(
        supabase_url=SB, supabase_anon_key="anon", public_redirect_base_url=BASE
    )
    app.dependency_overrides[get_current_user] = lambda: CurrentUser(
        id=USER, email=None, role="authenticated", raw_token="user-jwt"
    )
    with respx.mock(assert_all_called=False) as mock:

        def build(role: str | None = "editor") -> Backend:
            b = Backend(role)
            mock.post(f"{SB}/rest/v1/rpc/my_effective_role").mock(side_effect=b.memberships)
            mock.get(f"{SB}/rest/v1/dynamic_links").mock(side_effect=b.links)
            mock.route(url__startswith=f"{SB}/rest/v1/qr_designs").mock(side_effect=b.designs)
            mock.route(url__startswith=f"{SB}/storage/v1/object/").mock(side_effect=b.storage)
            return b

        yield build
    app.dependency_overrides.clear()


def png_bytes(fmt: str = "PNG", size: int = 200, info: bool = False) -> bytes:
    im = Image.new("RGB", (size, size), "#d33")
    out = io.BytesIO()
    if info and fmt == "PNG":
        from PIL.PngImagePlugin import PngInfo

        meta = PngInfo()
        meta.add_text("secret", "payload-oculto")
        im.save(out, format=fmt, pnginfo=meta)
    else:
        im.save(out, format=fmt)
    return out.getvalue()


def d(path: str = "design") -> str:
    return f"/v1/links/{LINK}/{path}"


# ---------------------------------------------------------------- roles


def test_roles(make: Any) -> None:
    for role, put_ok in (("viewer", False), ("editor", True), ("admin", True)):
        b = make(role)
        c = TestClient(app)
        assert c.get(d(), headers=H).status_code == 200
        assert c.put(d(), headers=H, json={}).status_code == (200 if put_ok else 403)
        up = c.post(d("design/logo"), headers=H, files={"file": ("l.png", png_bytes())})
        assert up.status_code == (201 if put_ok else 403)
        assert c.delete(d("design/logo"), headers=H).status_code == (200 if put_ok else 403)
        assert c.get(d("qr.png"), headers=H).status_code == 200
        assert b.auth_seen == {"Bearer user-jwt"}  # siempre el JWT del usuario


def test_non_member_403_and_other_org_404(make: Any) -> None:
    make(None)
    c = TestClient(app)
    assert c.get(d(), headers=H).status_code == 403
    assert c.get(d("qr.png"), headers=H).status_code == 403
    make("viewer")
    r = c.get(d(), headers={"X-Org-Id": str(uuid4())})
    assert r.status_code == 404 and r.json()["error"]["code"] == "link_not_found"


def test_unauthenticated(make: Any) -> None:
    make()
    app.dependency_overrides.pop(get_current_user)
    assert TestClient(app).get(d(), headers=H).status_code == 401


# ---------------------------------------------------------------- diseño


def test_get_default_design(make: Any) -> None:
    make("viewer")
    j = TestClient(app).get(d(), headers=H).json()
    assert j["is_default"] is True and j["fg"] == "#000000" and j["ecc_level"] == "M"
    assert j["has_logo"] is False


def test_put_upsert_and_get(make: Any) -> None:
    b = make("editor")
    c = TestClient(app)
    body = {
        "fg": "#123",
        "bg": "#FFFFFF",
        "ecc_level": "Q",
        "frame": "label",
        "module_style": "dots",
        "margin": 2,
        "frame_text": "Hola",
    }
    r = c.put(d(), headers=H, json=body)
    assert r.status_code == 200, r.text
    j = r.json()
    assert j["fg"] == "#112233" and j["frame"] == "label" and j["is_default"] is False
    assert any("Zona de silencio" in w for w in j["warnings"])
    assert b.design and b.design["style"] == {
        "module_style": "dots",
        "margin": 2,
        "frame_text": "Hola",
    }
    assert "logo_path" not in json.loads(json.dumps(b.design)) or b.design["logo_path"] is None
    assert c.get(d(), headers=H).json()["module_style"] == "dots"
    c.put(d(), headers=H, json={"fg": "#000000", "bg": "#000000"})  # 2.º PUT = update
    assert b.design["fg"] == "#000000"


@pytest.mark.parametrize(
    "body",
    [
        {"fg": "red"},
        {"bg": "#12"},
        {"ecc_level": "X"},
        {"frame": "x"},
        {"module_style": "x"},
        {"margin": 99},
        {"frame_text": "x" * 31},
        {"logo_path": "a/b.png"},
    ],
)
def test_put_invalid(make: Any, body: dict[str, Any]) -> None:
    make("editor")
    assert TestClient(app).put(d(), headers=H, json=body).status_code == 422


def test_put_with_logo_forces_ecc_h(make: Any) -> None:
    b = make("editor")
    c = TestClient(app)
    c.post(d("design/logo"), headers=H, files={"file": ("l.png", png_bytes())})
    j = c.put(d(), headers=H, json={"ecc_level": "L"}).json()
    assert j["ecc_level"] == "H" and j["has_logo"] is True
    assert b.design and b.design["ecc_level"] == "H"


def test_style_whitelist_ignores_bad_values(make: Any) -> None:
    b = make("viewer")
    b.design = {
        "link_id": LINK,
        "fg": "#000000",
        "bg": "#ffffff",
        "ecc_level": "M",
        "frame": "none",
        "logo_path": None,
        "style": {"module_style": "evil", "margin": 999, "__proto__": 1},
    }
    j = TestClient(app).get(d(), headers=H).json()
    assert j["module_style"] == "square" and j["margin"] == 4
    assert TestClient(app).get(d("qr.png"), headers=H).status_code == 200


# ---------------------------------------------------------------- logo


def test_logo_upload_reencodes_and_sets_ecc_h(make: Any) -> None:
    b = make("editor")
    c = TestClient(app)
    r = c.post(d("design/logo"), headers=H, files={"file": ("x.png", png_bytes(info=True))})
    assert r.status_code == 201, r.text
    assert r.json()["has_logo"] and r.json()["ecc_level"] == "H"
    path = b.design["logo_path"]
    assert path.startswith(f"{ORG}/{LINK}-") and path.endswith(".png")
    stored = Image.open(io.BytesIO(b.objects[path]))
    assert stored.format == "PNG" and "secret" not in stored.info and stored.mode == "RGBA"
    # JPEG y WebP se convierten a PNG
    for fmt in ("JPEG", "WEBP"):
        old = path
        assert (
            c.post(d("design/logo"), headers=H, files={"file": ("x", png_bytes(fmt))}).status_code
            == 201
        )
        path = b.design["logo_path"]
        assert path != old and old not in b.objects  # el logo anterior se borra
    # DELETE
    r = c.delete(d("design/logo"), headers=H)
    assert r.status_code == 200 and r.json()["has_logo"] is False
    assert b.design["logo_path"] is None and not b.objects


@pytest.mark.parametrize(
    "data",
    [b"", b"GIF89a....", b"<svg xmlns='http://www.w3.org/2000/svg'/>", b"\x89PNG\r\n\x1a\nbroken"],
)
def test_logo_invalid_formats(make: Any, data: bytes) -> None:
    b = make("editor")
    r = TestClient(app).post(d("design/logo"), headers=H, files={"file": ("x.png", data)})
    assert r.status_code == 422 and r.json()["error"]["code"] == "logo_invalid"
    assert not b.objects and b.design is None


def test_logo_too_big_and_pixel_bomb(make: Any) -> None:
    b = make("editor")
    c = TestClient(app)
    r = c.post(d("design/logo"), headers=H, files={"file": ("x.png", b"\0" * 1_000_001)})
    assert r.status_code == 413
    bomb = io.BytesIO()
    Image.new("1", (5000, 5000)).save(bomb, format="PNG")  # <1 MB, 25 Mpx
    assert len(bomb.getvalue()) < 1_000_000
    r = c.post(d("design/logo"), headers=H, files={"file": ("x.png", bomb.getvalue())})
    assert r.status_code == 422 and not b.objects


def test_logo_orphan_removed_if_db_fails(make: Any) -> None:
    b = make("editor")
    b.fail_db_write = True
    r = TestClient(app).post(d("design/logo"), headers=H, files={"file": ("x.png", png_bytes())})
    assert r.status_code == 422 and not b.objects


def test_plan_limit_reached_is_409(make: Any) -> None:
    b = make("editor")
    b.limit_hit = True
    c = TestClient(app)
    for r in (
        c.put(d(), headers=H, json={}),
        c.post(d("design/logo"), headers=H, files={"file": ("x.png", png_bytes())}),
    ):
        assert r.status_code == 409 and r.json()["error"]["code"] == "plan_limit_reached"
    assert not b.objects  # el logo subido se limpia


def test_body_limit_content_length(make: Any) -> None:
    b = make("editor")
    big = {"file": ("x.png", b"\0" * 1_200_000)}
    # sin autenticar o sin rol: se corta antes de parsear
    app.dependency_overrides.pop(get_current_user)
    r = TestClient(app).post(d("design/logo"), headers=H, files=big)
    assert r.status_code == 413 and r.json()["error"]["code"] == "payload_too_large"
    assert not b.auth_seen


def test_body_limit_chunked(make: Any) -> None:
    b = make("editor")

    def gen() -> Iterator[bytes]:
        yield b"--B\r\nContent-Disposition: form-data; name=file; filename=x.png\r\n\r\n"
        for _ in range(30):
            yield b"\0" * 50_000
        yield b"\r\n--B--\r\n"

    r = TestClient(app).post(
        d("design/logo"),
        headers={**H, "Content-Type": "multipart/form-data; boundary=B"},
        content=gen(),
    )
    assert r.status_code == 413 and not b.objects


def test_body_limit_only_logo_route(make: Any) -> None:
    make("editor")
    r = TestClient(app).put(d(), headers=H, json={"frame_text": "x" * 2_000_000})
    assert r.status_code == 422  # no 413: el límite solo aplica a la subida de logo


def test_logo_storage_denied(make: Any) -> None:
    b = make("editor")
    b.deny_storage = True
    r = TestClient(app).post(d("design/logo"), headers=H, files={"file": ("x.png", png_bytes())})
    assert r.status_code == 403 and b.design is None


def test_download_ignores_foreign_logo_path(make: Any) -> None:
    b = make("viewer")
    b.design = {
        "link_id": LINK,
        "fg": "#000000",
        "bg": "#ffffff",
        "ecc_level": "H",
        "frame": "none",
        "logo_path": f"{uuid4()}/x.png",
        "style": {},
    }
    assert TestClient(app).get(d("qr.png"), headers=H).status_code == 500


# ---------------------------------------------------------------- descargas


def test_download_png(make: Any) -> None:
    make("viewer")
    r = TestClient(app).get(d("qr.png?size=600"), headers=H)
    assert r.status_code == 200 and r.headers["content-type"] == "image/png"
    assert r.headers["content-disposition"] == f'attachment; filename="{SLUG}-qr.png"'
    assert "private" in r.headers["cache-control"]
    assert "x-qr-warnings" not in r.headers
    assert decode_png(r.content) == [URL]
    assert Image.open(io.BytesIO(r.content)).width == 600


def test_download_svg(make: Any) -> None:
    make("viewer")
    r = TestClient(app).get(d("qr.svg"), headers=H)
    assert r.headers["content-type"].startswith("image/svg+xml")
    assert r.headers["content-disposition"].endswith(f'{SLUG}-qr.svg"')
    assert decode(_raster_svg(r.text)) == [URL]


def test_download_pdf(make: Any) -> None:
    make("viewer")
    r = TestClient(app).get(d("qr.pdf?size=800&template=none"), headers=H)
    assert r.headers["content-type"] == "application/pdf"
    assert r.headers["content-disposition"].endswith(f'{SLUG}-qr.pdf"')
    page = pdfium.PdfDocument(r.content)[0]
    assert decode(page.render(scale=3).to_pil()) == [URL]


def test_download_with_design_and_logo_decodes(make: Any) -> None:
    make("editor")
    c = TestClient(app)
    c.put(d(), headers=H, json={"fg": "#112244", "frame": "rounded", "module_style": "rounded"})
    c.post(d("design/logo"), headers=H, files={"file": ("x.png", png_bytes())})
    assert decode_png(c.get(d("qr.png?size=700"), headers=H).content) == [URL]
    assert decode(_raster_svg(c.get(d("qr.svg"), headers=H).text)) == [URL]


def test_download_contrast_warning_header(make: Any) -> None:
    make("editor")
    c = TestClient(app)
    c.put(d(), headers=H, json={"fg": "#cccccc", "bg": "#ffffff"})
    r = c.get(d("qr.png"), headers=H)
    assert r.status_code == 200 and "Contraste%20bajo" in r.headers["x-qr-warnings"]


@pytest.mark.parametrize("q", ["size=127", "size=4097", "size=abc", "template=banner"])
def test_download_invalid_params(make: Any, q: str) -> None:
    make("viewer")
    assert TestClient(app).get(d(f"qr.png?{q}"), headers=H).status_code == 422


def test_download_bad_format(make: Any) -> None:
    make("viewer")
    assert TestClient(app).get(d("qr.gif"), headers=H).status_code == 422


def test_download_size_limits_ok(make: Any) -> None:
    make("viewer")
    c = TestClient(app)
    for s in (128, 4096):
        assert c.get(d(f"qr.png?size={s}"), headers=H).status_code == 200


# ---------------------------------------------------------------- preset de logo (T060)

PRESET = {"logo_preset": "google"}


def test_preset_put_get_forces_ecc_h_and_no_storage(make: Any) -> None:
    b = make("editor")
    c = TestClient(app)
    j = c.put(d(), headers=H, json={"ecc_level": "L", **PRESET}).json()
    assert j["logo_preset"] == "google" and j["ecc_level"] == "H" and j["has_logo"] is False
    assert j["style"]["logo_preset"] == "google"
    assert b.design and b.design["ecc_level"] == "H" and b.design["logo_path"] is None
    assert b.objects == {}  # no usa Storage ni cuota de logos
    assert c.get(d(), headers=H).json()["logo_preset"] == "google"
    # quitar el preset
    j = c.put(d(), headers=H, json={"ecc_level": "M"}).json()
    assert j["logo_preset"] is None and j["ecc_level"] == "M"


def test_preset_via_style_contract_of_web(make: Any) -> None:
    """La web envía {"style": {"logo_preset": ...}} (contrato DQR-T060)."""
    b = make("editor")
    c = TestClient(app)
    j = c.put(d(), headers=H, json={"fg": "#000000", "style": {"logo_preset": "google"}}).json()
    assert j["logo_preset"] == "google" and j["ecc_level"] == "H"
    assert b.design and b.design["logo_path"] is None
    j = c.put(d(), headers=H, json={"style": {"logo_preset": None}}).json()
    assert j["logo_preset"] is None


@pytest.mark.parametrize(
    "body",
    [
        {"style": {"logo_preset": "facebook"}},
        {"style": {"logo_preset": "google", "otra": 1}},
        {"style": {"module_style": "dots"}},
        {"logo_preset": "google", "style": {"logo_preset": None}},
    ],
)
def test_preset_via_style_invalid_422(make: Any, body: Any) -> None:
    make("editor")
    assert TestClient(app).put(d(), headers=H, json=body).status_code == 422


@pytest.mark.parametrize("value", ["facebook", "../../etc/passwd", "", 1, True])
def test_preset_invalid_422(make: Any, value: Any) -> None:
    make("editor")
    r = TestClient(app).put(d(), headers=H, json={"logo_preset": value})
    assert r.status_code == 422


def test_preset_bad_value_in_db_is_ignored(make: Any) -> None:
    b = make("viewer")
    b.design = {
        "link_id": LINK, "fg": "#000000", "bg": "#ffffff", "ecc_level": "M",
        "frame": "none", "logo_path": None, "style": {"logo_preset": "../x"},
    }  # fmt: skip
    j = TestClient(app).get(d(), headers=H).json()
    assert j["logo_preset"] is None
    assert TestClient(app).get(d("qr.png"), headers=H).status_code == 200


def test_preset_downloads_decode_png_svg_pdf(make: Any) -> None:
    b = make("editor")
    c = TestClient(app)
    c.put(d(), headers=H, json={"ecc_level": "L", **PRESET})
    r = c.get(d("qr.png?size=800"), headers=H)
    assert decode_png(r.content) == [URL]
    with_logo = Image.open(io.BytesIO(r.content)).convert("RGB")
    # el centro del QR lleva la G (colores, no solo negro/blanco)
    w = with_logo.width
    centre = with_logo.crop((w * 2 // 5, w * 2 // 5, w * 3 // 5, w * 3 // 5))
    assert any(abs(r_ - g_) > 60 or abs(g_ - b_) > 60 for r_, g_, b_ in centre.getdata())
    svg = c.get(d("qr.svg"), headers=H).text
    assert "data:image/png;base64," in svg and decode(_raster_svg(svg)) == [URL]
    pdf = c.get(d("qr.pdf?size=1000"), headers=H).content
    assert decode(pdfium.PdfDocument(pdf)[0].render(scale=3).to_pil()) == [URL]
    assert b.objects == {}


def test_preset_wins_over_logo_path_and_skips_storage(make: Any) -> None:
    b = make("editor")
    c = TestClient(app)
    c.post(d("design/logo"), headers=H, files={"file": ("l.png", png_bytes())})
    c.put(d(), headers=H, json=PRESET)
    assert b.design and b.design["logo_path"]  # el logo propio no se borra
    b.objects.clear()  # si se intentara leer de Storage → 404 → 502
    r = c.get(d("qr.png"), headers=H)
    assert r.status_code == 200 and decode_png(r.content) == [URL]
