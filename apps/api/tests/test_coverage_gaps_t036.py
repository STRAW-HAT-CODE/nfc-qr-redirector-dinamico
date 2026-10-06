"""DQR-T036 · huecos de decodificación y límites de QR (DQR-04). Solo tests.

Completa test_qr_render / test_qr_api / test_print_templates: toda combinación de formato ×
plantilla × marco × estilo (con y sin logo) se decodifica a BASE/r/{slug}?c=q, los límites de
`size` se comprueban en los tres formatos y el límite de 1 MB del logo en su frontera exacta.
"""

import io
from typing import Any

import pypdfium2 as pdfium
import pytest
from fastapi.testclient import TestClient
from PIL import Image

from app.main import app
from app.services.print_templates import SPECS, render_template
from app.services.qr_render import MAX_LOGO_BYTES, QrDesign, render_pdf, render_png, render_svg
from tests.test_print_templates import raster_svg
from tests.test_qr_api import URL, H, d, make, png_bytes  # noqa: F401  (make = fixture)
from tests.test_qr_render import _logo, _raster_svg, decode, decode_png

FRAMES = ["none", "simple", "rounded", "label"]
STYLES = ["square", "rounded", "dots"]


# ---------------------------------------------------------------- plantillas × formatos × diseño


@pytest.mark.parametrize("tpl", list(SPECS))
@pytest.mark.parametrize("with_logo", [False, True], ids=["plain", "logo"])
def test_every_template_format_decodes_with_and_without_logo(tpl: str, with_logo: bool) -> None:
    design = QrDesign(
        fg="#102030", bg="#fffbe6", frame="rounded", logo=_logo() if with_logo else None
    )
    svg = render_template(tpl, "svg", URL, design, "Mesa 7", False).decode()
    assert decode(raster_svg(svg)) == [URL]
    pdf = render_template(tpl, "pdf", URL, design, "Mesa 7", False)
    assert decode(pdfium.PdfDocument(pdf)[0].render(scale=4).to_pil()) == [URL]
    png = render_template(tpl, "png", URL, design, "Mesa 7", True)  # variante NFC del CTA
    assert decode_png(png) == [URL]


@pytest.mark.parametrize("frame", FRAMES)
@pytest.mark.parametrize("style", STYLES)
def test_sticker_png_pdf_decode_for_every_frame_and_style(frame: str, style: str) -> None:
    design = QrDesign(frame=frame, module_style=style, logo=_logo())  # type: ignore[arg-type]
    assert decode_png(render_template("sticker", "png", URL, design, "T", False)) == [URL]
    pdf = render_template("sticker", "pdf", URL, design, "T", False)
    assert decode(pdfium.PdfDocument(pdf)[0].render(scale=4).to_pil()) == [URL]


@pytest.mark.parametrize("frame", FRAMES)
def test_sticker_svg_decodes_for_every_frame(frame: str) -> None:
    """El rasterizador de test solo dibuja módulos cuadrados: el SVG con módulos redondeados o
    de puntos se comprobó aparte en Chromium real (qa-T036.md: 96/96)."""
    design = QrDesign(frame=frame, logo=_logo())  # type: ignore[arg-type]
    svg = render_template("sticker", "svg", URL, design, "T", False).decode()
    assert decode(raster_svg(svg)) == [URL]


@pytest.mark.parametrize("frame", FRAMES)
@pytest.mark.parametrize("style", STYLES)
def test_plain_qr_every_format_decodes_for_every_frame_and_style(frame: str, style: str) -> None:
    design = QrDesign(frame=frame, module_style=style, logo=_logo())  # type: ignore[arg-type]
    assert decode_png(render_png(URL, design, 640)) == [URL]
    assert decode(_raster_svg(render_svg(URL, design))) == [URL]
    assert decode(pdfium.PdfDocument(render_pdf(URL, design, 640))[0].render(scale=3).to_pil()) == [
        URL
    ]


# ---------------------------------------------------------------- API: límites de size y formatos


@pytest.mark.parametrize("fmt", ["png", "svg", "pdf"])
@pytest.mark.parametrize("size", [127, 4097, 0, -5])
def test_api_size_out_of_range_is_422_for_every_format(make: Any, fmt: str, size: int) -> None:  # noqa: F811
    make("viewer")
    r = TestClient(app).get(d(f"qr.{fmt}?size={size}"), headers=H)
    assert r.status_code == 422


@pytest.mark.parametrize("fmt", ["png", "svg", "pdf"])
@pytest.mark.parametrize("size", [128, 4096])
def test_api_size_boundaries_are_accepted_for_every_format(make: Any, fmt: str, size: int) -> None:  # noqa: F811
    make("viewer")
    r = TestClient(app).get(d(f"qr.{fmt}?size={size}"), headers=H)
    assert r.status_code == 200, (fmt, size, r.text[:100])
    if fmt == "png":
        im = Image.open(io.BytesIO(r.content))
        assert im.width == size and decode(im) == [URL]
    elif fmt == "pdf":
        # scale=4: a 128 px el módulo mide ~3 px y algunas escalas de pdfium (3, 10) no resuelven
        assert decode(pdfium.PdfDocument(r.content)[0].render(scale=4).to_pil()) == [URL]
    else:
        assert decode(_raster_svg(r.text)) == [URL]


def test_api_logo_design_decodes_in_every_format_and_is_ecc_h(make: Any) -> None:  # noqa: F811
    make("editor")
    c = TestClient(app)
    assert c.put(d(), headers=H, json={"fg": "#112244", "frame": "label"}).status_code == 200
    assert (
        c.post(d("design/logo"), headers=H, files={"file": ("l.png", png_bytes())}).status_code
        == 201
    )
    assert c.get(d(), headers=H).json()["ecc_level"] == "H"
    assert decode_png(c.get(d("qr.png?size=800"), headers=H).content) == [URL]
    assert decode(_raster_svg(c.get(d("qr.svg"), headers=H).text)) == [URL]
    pdf = c.get(d("qr.pdf?size=800"), headers=H).content
    assert decode(pdfium.PdfDocument(pdf)[0].render(scale=3).to_pil()) == [URL]


# ---------------------------------------------------------------- API: frontera del límite de logo


def test_logo_size_gate_boundary_exact(make: Any) -> None:  # noqa: F811
    """Exactamente 1 000 000 B pasa el filtro de tamaño (422 por no ser imagen); +1 B → 413."""
    b = make("editor")
    c = TestClient(app)
    at_limit = c.post(
        d("design/logo"), headers=H, files={"file": ("x.png", b"\0" * MAX_LOGO_BYTES)}
    )
    assert at_limit.status_code == 422 and not b.objects
    over = c.post(
        d("design/logo"), headers=H, files={"file": ("x.png", b"\0" * (MAX_LOGO_BYTES + 1))}
    )
    assert over.status_code == 413 and over.json()["error"]["code"] == "logo_too_large"


def test_large_but_valid_logo_under_1mb_is_accepted_and_normalized(make: Any) -> None:  # noqa: F811
    import random

    rnd = random.Random(7)
    im = Image.frombytes("RGB", (400, 400), bytes(rnd.getrandbits(8) for _ in range(400 * 400 * 3)))
    buf = io.BytesIO()
    im.save(buf, format="PNG")
    raw = buf.getvalue()
    assert 400_000 < len(raw) < MAX_LOGO_BYTES  # grande pero válido
    b = make("editor")
    r = TestClient(app).post(d("design/logo"), headers=H, files={"file": ("big.png", raw)})
    assert r.status_code == 201 and len(b.objects) == 1
    stored = next(iter(b.objects.values()))
    assert Image.open(io.BytesIO(stored)).format == "PNG"  # se reencodea siempre a PNG
