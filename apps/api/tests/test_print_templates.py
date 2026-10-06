"""Plantillas imprimibles (DQR-T033): SVG/PDF/PNG válidos, QR decodificable y medidas reales."""

import io
import re
from collections.abc import Iterator
from typing import Any
from uuid import uuid4

import httpx
import pypdfium2 as pdfium
import pytest
import respx
from fastapi.testclient import TestClient
from PIL import Image, ImageDraw

from app.auth import CurrentUser
from app.core.config import Settings, get_settings
from app.deps import get_current_user
from app.main import app
from app.services.print_templates import (
    CTA_NFC,
    CTA_QR,
    SPECS,
    Poly,
    Rect,
    Text,
    build_scene,
    clean_title,
    fit_title,
    render_template,
    text_width,
)
from app.services.qr_render import QrDesign, QrRenderError
from tests.test_qr_render import _logo, decode, decode_png

BASE = "https://go.example.com"
SLUG = "aB3dE9x"
URL = f"{BASE}/r/{SLUG}?c=q"
MM_PT = 72 / 25.4


def raster_svg(svg: str, px_per_mm: float = 12) -> Image.Image:
    """Rasteriza el SVG de plantilla (rects, grupo del QR con translate/scale y paths cuadrados)."""
    vb = [float(v) for v in re.search(r'viewBox="([^"]+)"', svg).group(1).split()]
    img = Image.new("RGB", (round(vb[2] * px_per_mm), round(vb[3] * px_per_mm)), "white")
    dr = ImageDraw.Draw(img)

    def rects(chunk: str, tx: float, ty: float, s: float) -> None:
        for m in re.finditer(r"<rect ([^>]*?)/>", chunk):
            a = dict(re.findall(r'([\w:]+)="([^"]*)"', m.group(1)))
            x, y = tx + float(a.get("x", 0)) * s, ty + float(a.get("y", 0)) * s
            w, h = float(a["width"]) * s, float(a["height"]) * s
            k = px_per_mm
            dr.rectangle((x * k, y * k, (x + w) * k, (y + h) * k), fill=a["fill"])

    def paths(chunk: str, tx: float, ty: float, s: float) -> None:
        for m in re.finditer(r'<path fill="([^"]+)" d="([^"]+)"/>', chunk):
            fill, d = m.groups()
            for seg in re.finditer(r"M([\d.]+) ([\d.]+)h1v1h-1z", d):
                x, y = tx + float(seg[1]) * s, ty + float(seg[2]) * s
                k = px_per_mm
                dr.rectangle((x * k, y * k, (x + s) * k, (y + s) * k), fill=fill)

    g = re.search(r'<g id="qr" transform="translate\(([\d.]+) ([\d.]+)\) scale\(([\d.]+)\)">', svg)
    inner = svg[g.end() : svg.index("</g>")]
    outer = svg[: g.start()]
    rects(outer, 0, 0, 1)
    tx, ty, s = (float(v) for v in g.groups())
    rects(inner, tx, ty, s)
    paths(inner, tx, ty, s)
    return img


def qr_decodes_ok(img: Image.Image, url: str = URL) -> bool:
    return decode(img) == [url]


# ------------------------------------------------------------------ escena / medidas


@pytest.mark.parametrize(
    ("tpl", "w", "h"), [("sticker", 56, 56), ("display", 105, 148), ("poster", 210, 297)]
)
def test_svg_valid_dimensions_and_canva_friendly(tpl: str, w: int, h: int) -> None:
    svg = render_template(tpl, "svg", URL, QrDesign(), "Mi Enlace", False).decode()
    assert svg.startswith("<?xml")
    assert f'viewBox="0 0 {w} {h}"' in svg
    assert f'width="{w}mm" height="{h}mm"' in svg
    assert "<text " in svg and ">Mi Enlace</text>" in svg and CTA_QR in svg
    for bad in ("<filter", "<mask", "<script", "dominant-baseline", "<foreignObject", "<style"):
        assert bad not in svg
    # XML bien formado
    import xml.dom.minidom as md

    md.parseString(svg.encode())


@pytest.mark.parametrize("tpl", ["sticker", "display", "poster"])
@pytest.mark.parametrize(
    "design",
    [
        QrDesign(),
        QrDesign(fg="#112244", bg="#f5f0e6", frame="label"),
        QrDesign(frame="rounded", frame_text="Hola", logo=_logo()),
    ],
    ids=["plain", "color-label", "rounded-logo"],
)
def test_pdf_decodes_and_size(tpl: str, design: QrDesign) -> None:
    pdf = render_template(tpl, "pdf", URL, design, "Cafetería Central", False)
    assert pdf.startswith(b"%PDF") and pdf.rstrip().endswith(b"%%EOF")
    page = pdfium.PdfDocument(pdf)[0]
    sp = SPECS[tpl]
    w, h = page.get_size()
    assert w == pytest.approx(sp.w * MM_PT, abs=0.1) and h == pytest.approx(sp.h * MM_PT, abs=0.1)
    assert qr_decodes_ok(page.render(scale=4).to_pil())


@pytest.mark.parametrize("tpl", ["sticker", "display", "poster"])
def test_pdf_is_vector_with_text(tpl: str) -> None:
    pdf = render_template(tpl, "pdf", URL, QrDesign(), "Mi título", False)
    page = pdfium.PdfDocument(pdf)[0]
    txt = page.get_textpage().get_text_range()
    assert "Mi título" in txt and CTA_QR in txt
    assert len(pdf) < 100_000  # vectorial, no un bitmap embebido


def test_pdf_sticker_has_trim_and_bleed_box() -> None:
    page = pdfium.PdfDocument(render_template("sticker", "pdf", URL, QrDesign(), "x", False))[0]
    t, b = page.get_trimbox(), page.get_bleedbox()
    assert t[2] - t[0] == pytest.approx(50 * MM_PT, abs=0.1)
    assert b[2] - b[0] == pytest.approx(56 * MM_PT, abs=0.1)


@pytest.mark.parametrize("tpl", ["sticker", "display", "poster"])
def test_svg_qr_decodes(tpl: str) -> None:
    svg = render_template(tpl, "svg", URL, QrDesign(fg="#102030"), "T", False).decode()
    assert qr_decodes_ok(raster_svg(svg))


@pytest.mark.parametrize("tpl", ["sticker", "display", "poster"])
def test_png_300dpi_size_and_decodes(tpl: str) -> None:
    data = render_template(tpl, "png", URL, QrDesign(logo=_logo(), frame="label"), "T", False)
    im = Image.open(io.BytesIO(data))
    sp = SPECS[tpl]
    assert im.size == (round(sp.w * 300 / 25.4), round(sp.h * 300 / 25.4))
    assert round(im.info["dpi"][0]) == 300
    assert qr_decodes_ok(im)


def test_nfc_changes_cta_and_qr_url_unchanged() -> None:
    svg = render_template("display", "svg", URL, QrDesign(), "T", True).decode()
    assert CTA_NFC in svg and CTA_QR not in svg
    assert qr_decodes_ok(raster_svg(svg))


def test_content_inside_safe_zone() -> None:
    for tpl, sp in SPECS.items():
        sc = build_scene(tpl, URL, QrDesign(frame="label"), "Un título largo " * 4, True)
        x0, y0, x1, y1 = sp.safe_rect
        for el in sc.elements:
            if isinstance(el, Rect) and el.id == "fondo":
                assert (el.w, el.h) == (sp.w, sp.h)  # el fondo cubre el sangrado
                continue
            if isinstance(el, Text):
                hw = text_width(el.s, el.size) / 2
                assert x0 - 0.01 <= el.x - hw and el.x + hw <= x1 + 0.01
                assert y0 <= el.y - el.size * 0.72 and el.y <= y1, (tpl, el.id)
                continue
            if isinstance(el, Poly):
                assert all(x0 <= x <= x1 and y0 <= y <= y1 for x, y in el.points), (tpl, el.id)
                continue
            ex, ey = el.x, el.y
            ew, eh = el.w, el.h
            assert x0 - 0.01 <= ex and ex + ew <= x1 + 0.01, (tpl, el)
            assert y0 - 0.01 <= ey and ey + eh <= y1 + 0.01, (tpl, el)


def test_qr_not_stretched_and_quiet_zone_kept() -> None:
    sc = build_scene("poster", URL, QrDesign(), "T")
    qr = next(e for e in sc.elements if not isinstance(e, (Rect, Text)))
    assert qr.w / qr.lay.width == pytest.approx(qr.h / qr.lay.height)
    assert qr.lay.ox >= 4  # zona de silencio de 4 módulos dentro del bloque


# ------------------------------------------------------------------ título


def test_title_escaped_wrapped_and_truncated() -> None:
    svg = render_template("sticker", "svg", URL, QrDesign(), "A&B <x>", False).decode()
    assert "A&amp;B &lt;x&gt;" in svg and "<x>" not in svg
    lines, size = fit_title("palabra " * 10, SPECS["poster"], 180)
    assert len(lines) <= 3
    lines, size = fit_title("x" * 80, SPECS["sticker"], 44)
    assert len(lines) == 1 and text_width(lines[0], size) <= 44.01
    # Texto fuera de latin-1 no rompe el PDF
    assert render_template("display", "pdf", URL, QrDesign(), "日本語 ✓", False).startswith(b"%PDF")


@pytest.mark.parametrize("bad", ["", "   ", "x" * 81, "a\x00b", "a\x07b"])
def test_clean_title_invalid(bad: str) -> None:
    with pytest.raises(QrRenderError):
        clean_title(bad)


def test_invalid_template_raises() -> None:
    with pytest.raises(QrRenderError):
        build_scene("banner", URL, QrDesign(), "T")


# ------------------------------------------------------------------ API

SB = "https://proj.supabase.co"
ORG = str(uuid4())
LINK = str(uuid4())
H = {"X-Org-Id": ORG}


@pytest.fixture
def api(request: pytest.FixtureRequest) -> Iterator[dict[str, Any]]:
    state: dict[str, Any] = {"nfc": False, "name": "Menú del día", "nfc_calls": 0}
    app.dependency_overrides[get_settings] = lambda: Settings(
        supabase_url=SB, supabase_anon_key="anon", public_redirect_base_url=BASE
    )
    app.dependency_overrides[get_current_user] = lambda: CurrentUser(
        id=str(uuid4()), email=None, role="authenticated", raw_token="jwt"
    )

    def nfc(req: httpx.Request) -> httpx.Response:
        state["nfc_calls"] += 1
        return httpx.Response(200, json=[{"id": "t"}] if state["nfc"] else [])

    with respx.mock(assert_all_called=False) as mock:
        mock.post(f"{SB}/rest/v1/rpc/my_effective_role").mock(
            return_value=httpx.Response(200, json="viewer")
        )
        mock.get(f"{SB}/rest/v1/dynamic_links").mock(
            side_effect=lambda r: httpx.Response(
                200, json=[{"id": LINK, "slug": SLUG, "name": state["name"]}]
            )
        )
        mock.route(url__startswith=f"{SB}/rest/v1/qr_designs").mock(
            return_value=httpx.Response(200, json=[])
        )
        mock.route(url__startswith=f"{SB}/rest/v1/nfc_tags").mock(side_effect=nfc)
        yield state
    app.dependency_overrides.clear()


def get(path: str, **params: Any) -> httpx.Response:
    return TestClient(app).get(f"/v1/links/{LINK}/{path}", headers=H, params=params)


@pytest.mark.parametrize("tpl", ["sticker", "display", "poster"])
def test_api_templates_all_formats(api: dict[str, Any], tpl: str) -> None:
    sp = SPECS[tpl]
    r = get("qr.svg", template=tpl)
    assert r.status_code == 200 and r.headers["content-type"].startswith("image/svg+xml")
    assert f'viewBox="0 0 {sp.w:g} {sp.h:g}"' in r.text and "Menú del día" in r.text
    assert f'filename="{SLUG}-{tpl}.svg"' in r.headers["content-disposition"]
    assert qr_decodes_ok(raster_svg(r.text))
    r = get("qr.pdf", template=tpl)
    assert r.status_code == 200 and r.content.startswith(b"%PDF")
    assert qr_decodes_ok(pdfium.PdfDocument(r.content)[0].render(scale=4).to_pil())
    r = get("qr.png", template=tpl, size=200)  # size se ignora: 300 dpi
    assert r.status_code == 200
    assert Image.open(io.BytesIO(r.content)).size[0] == round(sp.w * 300 / 25.4)
    assert decode_png(r.content) == [URL]


def test_api_title_override_and_nfc_cta(api: dict[str, Any]) -> None:
    r = get("qr.svg", template="display", title="Mesa 7")
    assert ">Mesa 7</text>" in r.text and CTA_QR in r.text
    api["nfc"] = True
    r = get("qr.svg", template="display")
    assert CTA_NFC in r.text


def test_api_long_name_default_title_truncated(api: dict[str, Any]) -> None:
    api["name"] = "N" * 120
    r = get("qr.svg", template="sticker")
    assert r.status_code == 200 and "…" in r.text  # 120 → ajustado y truncado


def test_api_invalid_template_and_title_422(api: dict[str, Any]) -> None:
    assert get("qr.svg", template="banner").status_code == 422
    assert get("qr.svg", template="poster", title="x" * 81).status_code == 422
    assert get("qr.svg", template="poster", title="").status_code == 422
    assert get("qr.svg", template="poster", title="a\x07b").status_code == 422


def test_api_none_template_does_not_query_nfc(api: dict[str, Any]) -> None:
    assert get("qr.svg").status_code == 200
    assert api["nfc_calls"] == 0


# ------------------------------------------------------------------ google_review (T060)


def test_google_review_scene_and_formats() -> None:
    from app.services.print_templates import GOOGLE_REVIEW_TEXT
    from app.services.qr_render import preset_logo

    design = QrDesign(ecc="H", logo=preset_logo("google"))
    svg = render_template(
        "google_review", "svg", URL, design, GOOGLE_REVIEW_TEXT, False, "Café Luna"
    ).decode()
    assert 'viewBox="0 0 105 148"' in svg
    assert svg.count("<polygon") == 5 and "Café Luna" in svg and "reseña" in svg
    assert "data:image/png;base64," in svg
    assert qr_decodes_ok(raster_svg(svg))
    pdf = render_template("google_review", "pdf", URL, design, GOOGLE_REVIEW_TEXT, False, "Café")
    assert pdf.startswith(b"%PDF")
    assert qr_decodes_ok(pdfium.PdfDocument(pdf)[0].render(scale=4).to_pil())
    png = render_template("google_review", "png", URL, design, GOOGLE_REVIEW_TEXT, False, "Café")
    img = Image.open(io.BytesIO(png))
    assert img.size == (round(105 / 25.4 * 300), round(148 / 25.4 * 300))
    assert qr_decodes_ok(img)


def test_google_review_content_inside_safe_zone() -> None:
    scene = build_scene("google_review", URL, QrDesign(), "Título " * 8, False, "Local " * 12)
    x0, y0, x1, y1 = scene.spec.safe_rect
    for el in scene.elements:
        if isinstance(el, Text):
            assert (
                x0 <= el.x - text_width(el.s, el.size) / 2
                and el.x + text_width(el.s, el.size) / 2 <= x1
            )
            assert el.y <= y1


def test_api_google_review_forces_preset_and_title(api: dict[str, Any]) -> None:
    for fmt in ("svg", "pdf", "png"):
        r = get(f"qr.{fmt}", template="google_review")
        assert r.status_code == 200, r.text
        assert f'filename="{SLUG}-google_review.{fmt}"' in r.headers["content-disposition"]
    svg = get("qr.svg", template="google_review").text
    assert "Déjanos tu reseña en Google" in svg and "Menú del día" in svg
    assert "data:image/png;base64," in svg and qr_decodes_ok(raster_svg(svg))
    svg = get("qr.svg", template="google_review", title="Cuéntanos tu visita").text
    assert "Cuéntanos tu visita" in svg and "Déjanos" not in svg and "Menú del día" in svg
    r = get("qr.png", template="google_review")
    assert qr_decodes_ok(Image.open(io.BytesIO(r.content)))
