"""Plantillas imprimibles (DQR-T033): sticker, display de mostrador y póster A4.

Una sola *escena* (lista de primitivas en mm) se emite a SVG, PDF vectorial y PNG a 300 dpi.
Funciones puras, sin BD ni red.

Medidas (mm):
- sticker: 50×50 de corte + 3 de sangrado por lado → lienzo 56×56 (zona segura 3 mm).
- display: A6 105×148 (zona segura 8 mm).
- poster: A4 210×297 (zona segura 15 mm).

Compatibilidad con Canva: texto como `<text>` (una línea por elemento, `y` = línea base, sin
`dominant-baseline`), sin filtros ni máscaras, `viewBox` en mm y fuentes de sistema
(Helvetica/Arial; en PDF la Helvetica estándar, sin licencias).
"""

from __future__ import annotations

import io
import unicodedata
import zlib
from dataclasses import dataclass
from typing import Literal
from xml.sax.saxutils import escape

from PIL import Image, ImageDraw, ImageFont

from app.services.qr_render import (
    QrDesign,
    QrRenderError,
    _dark_modules,
    _f,
    _is_finder,
    _Layout,
    _layout,
    _logo_fit,
    contrast_ratio,
    render_png,
    svg_body,
)

Template = Literal["sticker", "display", "poster"]
TEMPLATES: tuple[str, ...] = ("sticker", "display", "poster")
MAX_TITLE_LEN = 80
DPI = 300
FONT_FAMILY = "Helvetica, Arial, sans-serif"
CTA_QR = "Escanéame"
CTA_NFC = "Acerca tu móvil"
_MM_PT = 72 / 25.4

# Anchos de Helvetica-Bold (AFM, 1/1000 em) para ASCII 32..126.
_HB = [
    278, 333, 474, 556, 556, 889, 722, 238, 333, 333, 389, 584, 278, 333, 278, 278,
    556, 556, 556, 556, 556, 556, 556, 556, 556, 556, 333, 333, 584, 584, 584, 611,
    975, 722, 722, 722, 722, 667, 611, 778, 722, 278, 556, 722, 611, 833, 722, 778,
    667, 778, 722, 667, 611, 722, 667, 944, 667, 667, 611, 333, 278, 333, 584, 556,
    333, 556, 611, 556, 611, 556, 333, 611, 611, 278, 278, 556, 278, 889, 611, 611,
    611, 611, 389, 556, 333, 611, 556, 778, 556, 556, 500, 389, 280, 389, 584,
]  # fmt: skip


# --------------------------------------------------------------------------- especificación


@dataclass(frozen=True)
class Spec:
    name: str
    w: float  # lienzo (incluye sangrado)
    h: float
    bleed: float  # sangrado por lado (0 si no hay)
    safe: float  # zona segura: distancia al borde de corte
    title_size: float
    title_min: float
    title_lines: int
    title_y: float  # línea base de la primera línea
    qr_box: float  # lado del recuadro del QR
    qr_y: float
    pill_y: float
    pill_h: float
    cta_size: float

    @property
    def safe_rect(self) -> tuple[float, float, float, float]:
        m = self.bleed + self.safe
        return m, m, self.w - m, self.h - m


SPECS: dict[str, Spec] = {
    "sticker": Spec("sticker", 56, 56, 3, 3, 3.0, 2.2, 1, 9.2, 30, 10.5, 42.5, 6, 3.4),
    "display": Spec("display", 105, 148, 0, 8, 7.0, 4.5, 2, 22, 75, 38, 122, 12, 6.0),
    "poster": Spec("poster", 210, 297, 0, 15, 16.0, 9.0, 3, 42, 150, 95, 255, 20, 10.0),
}


# --------------------------------------------------------------------------- texto


def clean_title(title: str) -> str:
    t = " ".join(title.split())
    if not t or len(t) > MAX_TITLE_LEN or any(ord(c) < 32 or ord(c) == 127 for c in t):
        raise QrRenderError("title inválido (1-80 caracteres, sin control)")
    return t


def text_width(s: str, size: float) -> float:
    """Ancho aproximado en mm de `s` en Helvetica-Bold a `size` mm."""
    total = 0
    for ch in s:
        if ch == "…":
            total += 1000
            continue
        base = unicodedata.normalize("NFD", ch)[0]
        total += _HB[ord(base) - 32] if 32 <= ord(base) <= 126 else 556
    return total / 1000 * size


def _wrap(text: str, size: float, max_w: float) -> list[str]:
    lines: list[str] = []
    cur = ""
    for word in text.split(" "):
        while text_width(word, size) > max_w:  # palabra más ancha que la línea: cortar
            k = len(word)
            while k > 1 and text_width(word[:k], size) > max_w:
                k -= 1
            if cur:
                lines.append(cur)
                cur = ""
            lines.append(word[:k])
            word = word[k:]
        trial = f"{cur} {word}".strip()
        if text_width(trial, size) <= max_w:
            cur = trial
        else:
            lines.append(cur)
            cur = word
    if cur:
        lines.append(cur)
    return lines


def fit_title(text: str, spec: Spec, max_w: float) -> tuple[list[str], float]:
    """Ajusta el título: reduce la fuente hasta `title_min`; si aún no cabe, trunca con «…»."""
    size = spec.title_size
    while True:
        lines = _wrap(text, size, max_w)
        if len(lines) <= spec.title_lines:
            return lines, size
        if size - 0.5 >= spec.title_min:
            size -= 0.5
            continue
        lines = lines[: spec.title_lines]
        last = lines[-1]
        while last and text_width(last + "…", size) > max_w:
            last = last[:-1]
        lines[-1] = last.rstrip() + "…"
        return lines, size


# --------------------------------------------------------------------------- escena


@dataclass(frozen=True)
class Rect:
    x: float
    y: float
    w: float
    h: float
    fill: str
    rx: float = 0.0
    id: str | None = None


@dataclass(frozen=True)
class Text:
    id: str
    x: float  # centro
    y: float  # línea base
    size: float
    s: str
    fill: str


@dataclass(frozen=True)
class QrBlock:
    x: float
    y: float
    s: float  # mm por módulo
    lay: _Layout
    design: QrDesign
    payload: str

    @property
    def w(self) -> float:
        return self.lay.width * self.s

    @property
    def h(self) -> float:
        return self.lay.height * self.s


Element = Rect | Text | QrBlock


@dataclass(frozen=True)
class Scene:
    spec: Spec
    title: str
    cta: str
    elements: list[Element]


def _ink(design: QrDesign) -> str:
    """Color de texto: el del QR si contrasta con el fondo; si no, negro/blanco."""
    if contrast_ratio(design.fg, design.bg) >= 4.5:
        return design.fg
    return (
        "#000000"
        if contrast_ratio("#000000", design.bg) >= contrast_ratio("#ffffff", design.bg)
        else "#ffffff"
    )


def build_scene(
    template: str, payload: str, design: QrDesign, title: str, nfc: bool = False
) -> Scene:
    if template not in SPECS:
        raise QrRenderError("template inválido")
    sp = SPECS[template]
    title = clean_title(title)
    cta = CTA_NFC if nfc else CTA_QR
    ink = _ink(design)
    sx0, _, sx1, _ = sp.safe_rect
    cx = sp.w / 2
    els: list[Element] = [Rect(0, 0, sp.w, sp.h, design.bg, id="fondo")]

    lines, size = fit_title(title, sp, sx1 - sx0)
    for i, line in enumerate(lines, 1):
        els.append(Text(f"titulo-{i}", cx, sp.title_y + (i - 1) * size * 1.2, size, line, ink))

    lay = _layout(payload, design)
    s = min(sp.qr_box / lay.width, sp.qr_box / lay.height)
    els.append(QrBlock(cx - lay.width * s / 2, sp.qr_y, s, lay, design, payload))

    pad = sp.cta_size * 0.9
    pw = min(text_width(cta, sp.cta_size) + 2 * pad, sx1 - sx0)
    els.append(Rect(cx - pw / 2, sp.pill_y, pw, sp.pill_h, ink, rx=sp.pill_h / 2, id="cta-fondo"))
    base = sp.pill_y + sp.pill_h / 2 + sp.cta_size * 0.35
    els.append(Text("cta", cx, base, sp.cta_size, cta, design.bg))
    return Scene(sp, title, cta, els)


# --------------------------------------------------------------------------- SVG


def render_svg_template(scene: Scene) -> str:
    sp = scene.spec
    out = [
        '<?xml version="1.0" encoding="UTF-8"?>',
        '<svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" '
        f'viewBox="0 0 {_f(sp.w)} {_f(sp.h)}" width="{_f(sp.w)}mm" height="{_f(sp.h)}mm">',
        f"<title>{escape(scene.title)}</title>",
    ]
    for el in scene.elements:
        if isinstance(el, Rect):
            idattr = f' id="{el.id}"' if el.id else ""
            rx = f' rx="{_f(el.rx)}"' if el.rx else ""
            out.append(
                f'<rect{idattr} x="{_f(el.x)}" y="{_f(el.y)}" width="{_f(el.w)}" '
                f'height="{_f(el.h)}"{rx} fill="{el.fill}"/>'
            )
        elif isinstance(el, Text):
            out.append(
                f'<text id="{el.id}" x="{_f(el.x)}" y="{_f(el.y)}" fill="{el.fill}" '
                f'font-family="{FONT_FAMILY}" font-weight="bold" font-size="{_f(el.size)}" '
                f'text-anchor="middle">{escape(el.s)}</text>'
            )
        else:
            out.append(
                f'<g id="qr" transform="translate({_f(el.x)} {_f(el.y)}) scale({el.s:.5f})">'
            )
            out.extend(svg_body(el.lay, el.design))
            out.append("</g>")
    out.append("</svg>")
    return "\n".join(out)


# --------------------------------------------------------------------------- PDF


def _rgb(h: str) -> str:
    return " ".join(f"{int(h[i : i + 2], 16) / 255:.4f}" for i in (1, 3, 5))


def _n(v: float) -> str:
    return f"{v:.4f}".rstrip("0").rstrip(".") or "0"


def _rrect(x: float, y: float, w: float, h: float, r: float) -> str:
    r = min(r, w / 2, h / 2)
    if r <= 0:
        return f"{_n(x)} {_n(y)} {_n(w)} {_n(h)} re "
    k = 0.5523 * r
    x1, y1 = x + w, y + h
    return (
        f"{_n(x + r)} {_n(y)} m {_n(x1 - r)} {_n(y)} l "
        f"{_n(x1 - r + k)} {_n(y)} {_n(x1)} {_n(y + r - k)} {_n(x1)} {_n(y + r)} c "
        f"{_n(x1)} {_n(y1 - r)} l "
        f"{_n(x1)} {_n(y1 - r + k)} {_n(x1 - r + k)} {_n(y1)} {_n(x1 - r)} {_n(y1)} c "
        f"{_n(x + r)} {_n(y1)} l "
        f"{_n(x + r - k)} {_n(y1)} {_n(x)} {_n(y1 - r + k)} {_n(x)} {_n(y1 - r)} c "
        f"{_n(x)} {_n(y + r)} l "
        f"{_n(x)} {_n(y + r - k)} {_n(x + r - k)} {_n(y)} {_n(x + r)} {_n(y)} c h "
    )


def _circle(cx: float, cy: float, r: float) -> str:
    return _rrect(cx - r, cy - r, 2 * r, 2 * r, r)


def _pdf_str(s: str) -> bytes:
    b = s.encode("cp1252", "replace")
    return b.replace(b"\\", b"\\\\").replace(b"(", b"\\(").replace(b")", b"\\)")


def _pdf_qr(el: QrBlock, images: list[tuple[bytes, int, int]]) -> bytes:
    lay, d = el.lay, el.design
    ops = [f"q {el.s:.6f} 0 0 {el.s:.6f} {_n(el.x)} {_n(el.y)} cm "]
    if lay.border:
        ops.append(f"{_rgb(d.fg)} rg " + _rrect(0, 0, lay.width, lay.height, lay.corner) + "f ")
        ops.append(
            f"{_rgb(d.bg)} rg "
            + _rrect(1, 1, lay.width - 2, lay.width - 1, max(lay.corner - 1, 0))
            + "f "
        )
        if lay.band:
            label = d.label
            tw = text_width(label, 2.6)
            ops.append(
                f"{_rgb(d.bg)} rg BT /F1 2.6 Tf 1 0 0 -1 {_n(lay.width / 2 - tw / 2)} "
                f"{_n(lay.width + lay.band / 2 - 0.5 + 0.9)} Tm ("
            )
            ops.append(_pdf_str(label).decode("latin-1") + ") Tj ET ")
    else:
        ops.append(f"{_rgb(d.bg)} rg " + _rrect(0, 0, lay.width, lay.height, 0) + "f ")
    path: list[str] = []
    for r, c in _dark_modules(lay):
        x, y = lay.ox + c, lay.oy + r
        style = "square" if _is_finder(r, c, lay.n) else d.module_style
        if style == "square":
            path.append(f"{_n(x)} {_n(y)} 1 1 re ")
        elif style == "dots":
            path.append(_circle(x + 0.5, y + 0.5, 0.45))
        else:
            path.append(_rrect(x, y, 1, 1, 0.3))
    if path:
        ops.append(f"{_rgb(d.fg)} rg " + "".join(path) + "f ")
    fit = _logo_fit(d, lay)
    if fit and lay.logo_box:
        im, (lx, ly) = fit
        bx0, by0, bx1, by1 = lay.logo_box
        ops.append(f"{_rgb(d.bg)} rg " + _rrect(bx0, by0, bx1 - bx0, by1 - by0, 0) + "f ")
        scale = ((bx1 - bx0) - 1.0) / max(im.size)
        flat = Image.new("RGB", im.size, d.bg)
        flat.paste(im, mask=im.getchannel("A"))
        flat.thumbnail((512, 512), Image.Resampling.LANCZOS)
        images.append((zlib.compress(flat.tobytes()), *flat.size))
        ops.append(
            f"q {_n(im.width * scale)} 0 0 {_n(-im.height * scale)} {_n(lx)} "
            f"{_n(ly + im.height * scale)} cm /Im{len(images)} Do Q "
        )
    ops.append("Q ")
    return "".join(ops).encode("latin-1")


def render_pdf_template(scene: Scene) -> bytes:
    sp = scene.spec
    images: list[tuple[bytes, int, int]] = []
    k = _MM_PT
    body: list[bytes] = [f"{k:.6f} 0 0 {-k:.6f} 0 {sp.h * k:.4f} cm ".encode()]
    for el in scene.elements:
        if isinstance(el, Rect):
            body.append(f"{_rgb(el.fill)} rg {_rrect(el.x, el.y, el.w, el.h, el.rx)}f ".encode())
        elif isinstance(el, Text):
            x = el.x - text_width(el.s, el.size) / 2
            body.append(
                f"{_rgb(el.fill)} rg BT /F1 {_n(el.size)} Tf 1 0 0 -1 "
                f"{_n(x)} {_n(el.y)} Tm (".encode()
                + _pdf_str(el.s)
                + b") Tj ET "
            )
        else:
            body.append(_pdf_qr(el, images))
    content = zlib.compress(b"".join(body))

    objs: list[bytes] = []
    n_img = len(images)
    xobj = "".join(f"/Im{i + 1} {6 + i} 0 R " for i in range(n_img))
    wpt, hpt = sp.w * k, sp.h * k
    boxes = ""
    if sp.bleed:
        b = sp.bleed * k
        boxes = (
            f"/TrimBox [{b:.3f} {b:.3f} {wpt - b:.3f} {hpt - b:.3f}] "
            f"/BleedBox [0 0 {wpt:.3f} {hpt:.3f}] "
        )
    objs.append(b"<< /Type /Catalog /Pages 2 0 R >>")
    objs.append(b"<< /Type /Pages /Kids [3 0 R] /Count 1 >>")
    objs.append(
        (
            f"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 {wpt:.3f} {hpt:.3f}] {boxes}"
            f"/Resources << /Font << /F1 4 0 R >> /XObject << {xobj}>> >> /Contents 5 0 R >>"
        ).encode()
    )
    objs.append(
        b"<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica-Bold /Encoding /WinAnsiEncoding >>"
    )
    objs.append(
        f"<< /Length {len(content)} /Filter /FlateDecode >>\nstream\n".encode()
        + content
        + b"\nendstream"
    )
    for data, iw, ih in images:
        objs.append(
            (
                f"<< /Type /XObject /Subtype /Image /Width {iw} /Height {ih} "
                f"/ColorSpace /DeviceRGB /BitsPerComponent 8 /Filter /FlateDecode "
                f"/Length {len(data)} >>\nstream\n"
            ).encode()
            + data
            + b"\nendstream"
        )
    out = io.BytesIO()
    out.write(b"%PDF-1.4\n%\xe2\xe3\xcf\xd3\n")
    offsets: list[int] = []
    for i, o in enumerate(objs, 1):
        offsets.append(out.tell())
        out.write(f"{i} 0 obj\n".encode() + o + b"\nendobj\n")
    xref = out.tell()
    out.write(f"xref\n0 {len(objs) + 1}\n0000000000 65535 f \n".encode())
    for off in offsets:
        out.write(f"{off:010d} 00000 n \n".encode())
    out.write(
        f"trailer\n<< /Size {len(objs) + 1} /Root 1 0 R >>\nstartxref\n{xref}\n%%EOF\n".encode()
    )
    return out.getvalue()


# --------------------------------------------------------------------------- PNG


def render_png_template(scene: Scene) -> bytes:
    sp = scene.spec
    ppm = DPI / 25.4
    img = Image.new("RGB", (round(sp.w * ppm), round(sp.h * ppm)), "white")
    d = ImageDraw.Draw(img)
    for el in scene.elements:
        if isinstance(el, Rect):
            box = (el.x * ppm, el.y * ppm, (el.x + el.w) * ppm - 1, (el.y + el.h) * ppm - 1)
            if el.rx:
                d.rounded_rectangle(box, radius=el.rx * ppm, fill=el.fill)
            else:
                d.rectangle(box, fill=el.fill)
        elif isinstance(el, Text):
            font = ImageFont.load_default(size=max(8, round(el.size * ppm * 1.05)))
            d.text((el.x * ppm, el.y * ppm), el.s, fill=el.fill, font=font, anchor="ms")
        else:
            px = max(128, round(el.w * ppm))
            qr = Image.open(io.BytesIO(render_png(el.payload, el.design, px)))
            img.paste(qr.convert("RGB"), (round(el.x * ppm), round(el.y * ppm)))
    out = io.BytesIO()
    img.save(out, format="PNG", dpi=(DPI, DPI), optimize=True)
    return out.getvalue()


# --------------------------------------------------------------------------- API


def render_template(
    template: str,
    fmt: Literal["svg", "pdf", "png"],
    payload: str,
    design: QrDesign,
    title: str,
    nfc: bool = False,
) -> bytes:
    scene = build_scene(template, payload, design, title, nfc)
    if fmt == "svg":
        return render_svg_template(scene).encode("utf-8")
    if fmt == "pdf":
        return render_pdf_template(scene)
    return render_png_template(scene)
