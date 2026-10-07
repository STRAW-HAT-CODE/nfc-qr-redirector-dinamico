import io

import pypdfium2 as pdfium
import pytest
import zxingcpp
from PIL import Image, ImageDraw

from app.services.qr_render import (
    QrDesign,
    QrRenderError,
    check_design,
    contrast_ratio,
    qr_payload,
    render_pdf,
    render_png,
    render_svg,
)

BASE = "https://go.example.com"
SLUG = "aB3dE9x"
URL = f"{BASE}/r/{SLUG}?c=q"


def _logo(fmt: str = "PNG", size: int = 200) -> bytes:
    im = Image.new("RGB", (size, size), "#d33")
    out = io.BytesIO()
    im.save(out, format=fmt)
    return out.getvalue()


def decode(img: Image.Image) -> list[str]:
    return [r.text for r in zxingcpp.read_barcodes(img)]


def decode_png(data: bytes) -> list[str]:
    return decode(Image.open(io.BytesIO(data)))


# ------------------------------------------------------------------ payload


def test_payload_qr_and_nfc():
    assert qr_payload(BASE, SLUG) == URL
    assert qr_payload(BASE + "/", SLUG) == URL
    assert qr_payload(BASE, SLUG, "n") == f"{BASE}/r/{SLUG}?c=n"
    assert qr_payload(BASE, SLUG, "n", "tag_01") == f"{BASE}/r/{SLUG}?c=n&t=tag_01"


@pytest.mark.parametrize("slug", ["", "short", "toolongslug", "aB3dE9!", "aB3dE9é"])
def test_payload_invalid_slug(slug):
    with pytest.raises(QrRenderError):
        qr_payload(BASE, slug)


def test_payload_invalid_other():
    with pytest.raises(QrRenderError):
        qr_payload("ftp://x.com", SLUG)
    with pytest.raises(QrRenderError):
        qr_payload(BASE, SLUG, "q", "t")
    with pytest.raises(QrRenderError):
        qr_payload(BASE, SLUG, "n", "bad tag&x")
    with pytest.raises(QrRenderError):
        qr_payload(BASE, SLUG, "x")  # type: ignore[arg-type]


# ------------------------------------------------------------------ decode matrix


COLORS = [("#000000", "#ffffff"), ("#1a3c8f", "#ffffff"), ("#0b6b3a", "#f4f1de"), ("#222", "#fff")]


@pytest.mark.parametrize(("fg", "bg"), COLORS)
@pytest.mark.parametrize("ecc", ["L", "M", "Q", "H"])
def test_png_colors_and_ecc(fg, bg, ecc):
    assert decode_png(render_png(URL, QrDesign(fg=fg, bg=bg, ecc=ecc), 512)) == [URL]


@pytest.mark.parametrize("frame", ["none", "simple", "rounded", "label"])
@pytest.mark.parametrize("style", ["square", "rounded", "dots"])
@pytest.mark.parametrize("with_logo", [False, True])
def test_png_frame_style_logo(frame, style, with_logo):
    d = QrDesign(
        frame=frame,
        module_style=style,
        logo=_logo() if with_logo else None,
        fg="#10204a",
    )
    assert decode_png(render_png(URL, d, 600)) == [URL]


@pytest.mark.parametrize("fmt", ["PNG", "JPEG", "WEBP"])
def test_logo_formats(fmt):
    assert decode_png(render_png(URL, QrDesign(logo=_logo(fmt)), 512)) == [URL]


def test_nfc_payload_decodes():
    p = qr_payload(BASE, SLUG, "n", "abc")
    assert decode_png(render_png(p, QrDesign(), 400)) == [p]


@pytest.mark.parametrize("size", [128, 300, 1024, 4096])
def test_sizes(size):
    data = render_png(URL, QrDesign(margin=4), size)
    img = Image.open(io.BytesIO(data))
    assert img.width == size
    assert decode(img) == [URL]


def test_label_text_custom_and_height():
    img = Image.open(io.BytesIO(render_png(URL, QrDesign(frame="label", frame_text="Menú"), 512)))
    assert img.height > img.width


def test_logo_forces_ecc_h():
    d = QrDesign(ecc="L", logo=_logo())
    assert d.effective_ecc == "H"
    assert any("H" in w for w in check_design(d))


# ------------------------------------------------------------------ SVG / PDF


def _raster_svg(svg: str, px: int = 900) -> Image.Image:
    """Rasteriza el SVG con pdfium vía conversión mínima: dibuja path/rect del propio SVG."""
    import re

    from PIL import ImageDraw

    vb = [float(v) for v in re.search(r'viewBox="([^"]+)"', svg).group(1).split()]
    k = px / vb[2]
    img = Image.new("RGB", (px, round(vb[3] * k)), "white")
    d = ImageDraw.Draw(img)
    for m in re.finditer(r"<rect ([^>]*?)/>", svg):
        a = dict(re.findall(r'([\w:]+)="([^"]*)"', m.group(1)))
        x, y = float(a.get("x", 0)), float(a.get("y", 0))
        d.rectangle(
            (x * k, y * k, (x + float(a["width"])) * k, (y + float(a["height"])) * k),
            fill=a["fill"],
        )
    for m in re.finditer(r'<path fill="([^"]+)" d="([^"]+)"/>', svg):
        fill, path = m.groups()
        for seg in re.finditer(r"M([\d.]+) ([\d.]+)([^M]*)", path):
            x, y, rest = float(seg[1]), float(seg[2]), seg[3]
            if rest.startswith("h1v1"):
                d.rectangle((x * k, y * k, (x + 1) * k, (y + 1) * k), fill=fill)
            elif rest.startswith("a0.45"):  # punto
                d.ellipse(((x - 0.05) * k, (y - 0.5) * k, (x + 0.95) * k, (y + 0.5) * k), fill=fill)
            else:  # redondeado: aprox. por su bounding box
                d.rounded_rectangle(
                    ((x - 0.3) * k, y * k, (x + 0.7) * k, (y + 1) * k), radius=0.3 * k, fill=fill
                )
    return img


@pytest.mark.parametrize("frame", ["none", "simple", "rounded", "label"])
@pytest.mark.parametrize("style", ["square", "rounded", "dots"])
def test_svg_decodes(frame, style):
    svg = render_svg(URL, QrDesign(frame=frame, module_style=style, fg="#112244"))
    assert svg.startswith("<?xml") and "<script" not in svg
    assert decode(_raster_svg(svg)) == [URL]


def test_svg_with_logo_and_text_escaped():
    svg = render_svg(URL, QrDesign(logo=_logo(), frame="label", frame_text="A&B <x>"))
    assert "data:image/png;base64," in svg
    assert "A&amp;B &lt;x&gt;" in svg
    assert decode(_raster_svg(svg)) == [URL]


@pytest.mark.parametrize("frame", ["none", "label"])
def test_pdf_decodes(frame):
    pdf = render_pdf(URL, QrDesign(frame=frame, logo=_logo()), 1024)
    assert pdf.startswith(b"%PDF")
    page = pdfium.PdfDocument(pdf)[0]
    assert decode(page.render(scale=3).to_pil()) == [URL]


# ------------------------------------------------------------------ contraste


def test_contrast_ratio_wcag():
    assert contrast_ratio("#000", "#fff") == pytest.approx(21.0)
    assert contrast_ratio("#fff", "#fff") == pytest.approx(1.0)
    assert contrast_ratio("#777777", "#ffffff") == pytest.approx(4.48, abs=0.02)


def test_check_design_warnings():
    assert check_design(QrDesign()) == []
    low = check_design(QrDesign(fg="#999999", bg="#ffffff"))
    assert any("Contraste bajo" in w for w in low)
    inv = check_design(QrDesign(fg="#ffffff", bg="#000000"))
    assert any("invertidos" in w for w in inv)
    assert any("silencio" in w for w in check_design(QrDesign(margin=2)))


# ------------------------------------------------------------------ validaciones


@pytest.mark.parametrize("bad", ["red", "#12", "#12345g", "000000", "#1234567", ""])
def test_invalid_colors(bad):
    with pytest.raises(QrRenderError):
        QrDesign(fg=bad)
    with pytest.raises(QrRenderError):
        QrDesign(bg=bad)


@pytest.mark.parametrize("size", [127, 4097, 0, -1])
def test_invalid_size(size):
    with pytest.raises(QrRenderError):
        render_png(URL, QrDesign(), size)
    with pytest.raises(QrRenderError):
        render_pdf(URL, QrDesign(), size)


def test_invalid_enums_and_margin():
    for kw in ({"ecc": "X"}, {"frame": "x"}, {"module_style": "x"}, {"margin": 99}):
        with pytest.raises(QrRenderError):
            QrDesign(**kw)  # type: ignore[arg-type]
    with pytest.raises(QrRenderError):
        QrDesign(frame_text="x" * 31)
    with pytest.raises(QrRenderError):
        QrDesign(frame_text="a\nb")


def test_invalid_logo():
    with pytest.raises(QrRenderError):
        QrDesign(logo=b"not an image")
    with pytest.raises(QrRenderError):
        QrDesign(logo=b"")
    buf = io.BytesIO()
    Image.new("RGB", (20, 20)).save(buf, format="GIF")
    with pytest.raises(QrRenderError):
        QrDesign(logo=buf.getvalue())  # formato no permitido
    with pytest.raises(QrRenderError):
        QrDesign(logo=b"\x89PNG" + b"0" * 1_000_000)  # demasiado grande


def test_logo_pixel_bomb_rejected():
    buf = io.BytesIO()
    Image.new("1", (3000, 3000)).save(buf, format="PNG", optimize=True)  # ~9 Mpx, pocos bytes
    assert len(buf.getvalue()) < 1_000_000
    with pytest.raises(QrRenderError):
        QrDesign(logo=buf.getvalue())


def test_logo_area_at_most_20_percent():
    from app.services.qr_render import _layout

    for slug in ("aB3dE9x", "ZZZZZZZ"):
        lay = _layout(qr_payload(BASE, slug), QrDesign(logo=_logo()))
        assert lay.logo_box is not None
        x0, y0, x1, y1 = lay.logo_box
        assert (x1 - x0) * (y1 - y0) <= 0.2 * lay.n**2


def test_logo_load_does_not_change_max_image_pixels():
    before = Image.MAX_IMAGE_PIXELS
    QrDesign(logo=_logo())
    with pytest.raises(QrRenderError):
        QrDesign(logo=b"not an image")
    assert before == Image.MAX_IMAGE_PIXELS


# ------------------------------------------------------------------ fondo transparente (T061)


def _flat(png: bytes, bg: str) -> Image.Image:
    im = Image.open(io.BytesIO(png)).convert("RGBA")
    return Image.alpha_composite(Image.new("RGBA", im.size, bg), im).convert("RGB")


@pytest.mark.parametrize("frame", ["none", "label"])
@pytest.mark.parametrize("style", ["square", "dots"])
@pytest.mark.parametrize("with_logo", [False, True])
@pytest.mark.parametrize("bg", ["#ffffff", "#eeeeee"])
def test_transparent_png_decodes(frame, style, with_logo, bg):
    d = QrDesign(
        frame=frame,
        module_style=style,
        logo=_logo() if with_logo else None,
        bg_transparent=True,
    )
    png = render_png(URL, d, 600)
    assert URL in decode(_flat(png, bg))


def test_transparent_png_alpha_zero_outside_modules_and_logo():
    d = QrDesign(bg_transparent=True, margin=4)
    im = Image.open(io.BytesIO(render_png(URL, d, 512)))
    assert im.mode == "RGBA"
    a = im.getchannel("A")
    assert a.getpixel((0, 0)) == 0 and a.getpixel((511, 511)) == 0  # margen
    # todo píxel opaco es módulo (oscuro); el resto es alfa 0
    px = im.load()
    assert px is not None
    for y in range(0, 512, 7):
        for x in range(0, 512, 7):
            r, g, b, al = px[x, y]
            assert al == 0 or (r < 128 and g < 128 and b < 128)  # transparente o módulo negro
    assert any(px[x, y][3] == 255 for y in range(0, 512, 3) for x in range(0, 512, 3))


def test_transparent_png_logo_clear_area_is_transparent():
    logo = Image.new("RGBA", (50, 50), (0, 0, 0, 0))  # logo totalmente transparente
    ImageDraw.Draw(logo).ellipse((20, 20, 30, 30), fill=(255, 0, 0, 255))
    buf = io.BytesIO()
    logo.save(buf, format="PNG")
    d = QrDesign(bg_transparent=True, logo=buf.getvalue())
    im = Image.open(io.BytesIO(render_png(URL, d, 512)))
    c = im.size[0] // 2
    # el centro es el logo (rojo opaco); su alrededor inmediato (área despejada) es alfa 0
    assert im.getpixel((c, c))[3] == 255
    assert im.getpixel((c + 25, c))[3] == 0 or im.getpixel((c - 25, c))[3] == 0


def test_transparent_svg_has_no_background_rect():
    svg = render_svg(URL, QrDesign(bg_transparent=True))
    assert "<rect" not in svg
    svg_logo = render_svg(URL, QrDesign(bg_transparent=True, logo=_logo()))
    assert "<rect" not in svg_logo and "<image" in svg_logo
    framed = render_svg(URL, QrDesign(bg_transparent=True, frame="rounded"))
    assert "<rect" not in framed and 'fill-rule="evenodd"' in framed
    assert "<rect" in render_svg(URL, QrDesign())  # sin transparencia sigue habiendo fondo


def test_transparent_svg_decodes_on_white():
    # el rasterizador de test pinta sobre blanco; sin rect de fondo solo quedan los módulos
    img = _raster_svg(render_svg(URL, QrDesign(bg_transparent=True)), 600)
    assert URL in decode(img)


def test_transparent_pdf_stays_white():
    pdf = render_pdf(URL, QrDesign(bg_transparent=True), 512)
    page = pdfium.PdfDocument(pdf)[0]
    img = page.render(scale=2).to_pil().convert("RGB")
    assert img.getpixel((2, 2)) == (255, 255, 255)
    assert URL in decode(img)


def test_transparent_warning_and_contrast_against_white():
    w = check_design(QrDesign(bg_transparent=True))
    assert any("Fondo transparente" in x and "superficie clara" in x for x in w)
    # bg oscuro irrelevante: el contraste se mide contra blanco
    assert not any(
        "Contraste bajo" in x for x in check_design(QrDesign(bg="#000000", bg_transparent=True))
    )
    assert any(
        "Contraste bajo" in x for x in check_design(QrDesign(fg="#eeeeee", bg_transparent=True))
    )
    assert not any("Fondo transparente" in x for x in check_design(QrDesign()))


def test_bg_transparent_must_be_bool():
    with pytest.raises(QrRenderError):
        QrDesign(bg_transparent="yes")  # type: ignore[arg-type]
