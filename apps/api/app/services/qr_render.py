"""Generación de QR (DQR-T030): payload, diseño, PNG/SVG/PDF y avisos de contraste.

Funciones puras, sin BD. La matriz la calcula segno; el dibujo (estilos de módulo,
marco, logo) es propio para que PNG y SVG compartan exactamente la misma geometría.

Convenciones:
- `margin` es la zona de silencio en *módulos* (mín. recomendado por la norma: 4).
- `size` es el ancho final en px; con marco `label` la altura es algo mayor.
- Con logo se fuerza ECC H y el logo (con su fondo de seguridad) ocupa ≤ ~20 % del área.
"""

from __future__ import annotations

import base64
import io
import math
import re
from collections.abc import Iterator
from dataclasses import dataclass
from typing import Literal
from urllib.parse import quote, urlsplit
from xml.sax.saxutils import escape

import segno
from PIL import Image, ImageDraw, ImageFont, UnidentifiedImageError

from app.services.slug import is_valid_slug

Channel = Literal["q", "n"]
Ecc = Literal["L", "M", "Q", "H"]
Frame = Literal["none", "simple", "rounded", "label"]
ModuleStyle = Literal["square", "rounded", "dots"]

MIN_SIZE = 128
MAX_SIZE = 4096
MAX_LOGO_BYTES = 1_000_000
MAX_LOGO_PIXELS = 4_000_000  # anti decompression bomb
MAX_LABEL_LEN = 30
LOGO_AREA_FRACTION = 0.20
CONTRAST_MIN = 4.5

_HEX_RE = re.compile(r"^#(?:[0-9a-fA-F]{3}|[0-9a-fA-F]{6})$")
_TAG_RE = re.compile(r"^[A-Za-z0-9_-]{1,64}$")
_LOGO_FORMATS = {"PNG", "JPEG", "WEBP"}
_ECC_LEVELS = ("L", "M", "Q", "H")
_FRAMES = ("none", "simple", "rounded", "label")
_STYLES = ("square", "rounded", "dots")


class QrRenderError(ValueError):
    """Entrada inválida para la generación de QR."""


# --------------------------------------------------------------------------- payload


def qr_payload(base_url: str, slug: str, channel: Channel = "q", tag: str | None = None) -> str:
    """URL codificada: `{base}/r/{slug}?c=q` o `?c=n&t={tag}` (ADR-0004)."""
    if not is_valid_slug(slug):
        raise QrRenderError("slug inválido")
    parts = urlsplit(base_url)
    if parts.scheme not in ("http", "https") or not parts.netloc or parts.query or parts.fragment:
        raise QrRenderError("base_url inválida")
    base = base_url.rstrip("/")
    if channel == "q":
        if tag is not None:
            raise QrRenderError("tag solo aplica al canal NFC")
        return f"{base}/r/{slug}?c=q"
    if channel == "n":
        if tag is None:
            return f"{base}/r/{slug}?c=n"
        if not _TAG_RE.match(tag):
            raise QrRenderError("tag inválido")
        return f"{base}/r/{slug}?c=n&t={quote(tag, safe='')}"
    raise QrRenderError("canal inválido")


# --------------------------------------------------------------------------- diseño


def _norm_hex(value: str, field: str) -> str:
    if not isinstance(value, str) or not _HEX_RE.match(value):
        raise QrRenderError(f"{field}: color hex inválido")
    v = value.lower()
    if len(v) == 4:
        v = "#" + "".join(c * 2 for c in v[1:])
    return v


@dataclass(frozen=True)
class QrDesign:
    fg: str = "#000000"
    bg: str = "#ffffff"
    ecc: Ecc = "M"
    logo: bytes | None = None
    frame: Frame = "none"
    frame_text: str | None = None  # solo marco "label"; por defecto "Escanéame"
    module_style: ModuleStyle = "square"
    margin: int = 4

    def __post_init__(self) -> None:
        object.__setattr__(self, "fg", _norm_hex(self.fg, "fg"))
        object.__setattr__(self, "bg", _norm_hex(self.bg, "bg"))
        if self.ecc not in _ECC_LEVELS:
            raise QrRenderError("ecc inválido")
        if self.frame not in _FRAMES:
            raise QrRenderError("frame inválido")
        if self.module_style not in _STYLES:
            raise QrRenderError("module_style inválido")
        if not isinstance(self.margin, int) or not 0 <= self.margin <= 16:
            raise QrRenderError("margin debe estar entre 0 y 16 módulos")
        if self.frame_text is not None and (
            len(self.frame_text) > MAX_LABEL_LEN
            or any(ord(c) < 32 or ord(c) == 127 for c in self.frame_text)
        ):
            raise QrRenderError("frame_text inválido")
        if self.logo is not None:
            _load_logo(self.logo)  # valida

    @property
    def effective_ecc(self) -> Ecc:
        return "H" if self.logo is not None else self.ecc

    @property
    def label(self) -> str:
        return self.frame_text if self.frame_text else "Escanéame"


def _check_size(size: int) -> None:
    if not isinstance(size, int) or isinstance(size, bool) or not MIN_SIZE <= size <= MAX_SIZE:
        raise QrRenderError(f"size debe estar entre {MIN_SIZE} y {MAX_SIZE}")


def _load_logo(data: bytes) -> Image.Image:
    """Abre y valida el logo (formato, bytes y píxeles) y lo devuelve como RGBA."""
    if not isinstance(data, bytes | bytearray) or not data:
        raise QrRenderError("logo inválido")
    if len(data) > MAX_LOGO_BYTES:
        raise QrRenderError("logo demasiado grande")
    try:
        with Image.open(io.BytesIO(bytes(data)), formats=sorted(_LOGO_FORMATS)) as im:
            if im.width * im.height > MAX_LOGO_PIXELS:
                raise QrRenderError("logo con demasiados píxeles")
            im.load()
            return im.convert("RGBA")
    except QrRenderError:
        raise
    except (UnidentifiedImageError, Image.DecompressionBombError, OSError, ValueError) as exc:
        raise QrRenderError("logo: formato no soportado o corrupto") from exc


# --------------------------------------------------------------------------- contraste


def _rgb(h: str) -> tuple[int, int, int]:
    h = _norm_hex(h, "color")
    return int(h[1:3], 16), int(h[3:5], 16), int(h[5:7], 16)


def _luminance(h: str) -> float:
    def ch(c: int) -> float:
        s = c / 255
        return s / 12.92 if s <= 0.03928 else ((s + 0.055) / 1.055) ** 2.4

    r, g, b = (ch(c) for c in _rgb(h))
    return 0.2126 * r + 0.7152 * g + 0.0722 * b


def contrast_ratio(fg: str, bg: str) -> float:
    """Ratio de contraste WCAG (1..21)."""
    a, b = _luminance(fg), _luminance(bg)
    hi, lo = max(a, b), min(a, b)
    return (hi + 0.05) / (lo + 0.05)


def check_design(design: QrDesign) -> list[str]:
    """Avisos (no bloqueantes) sobre legibilidad."""
    warnings: list[str] = []
    ratio = contrast_ratio(design.fg, design.bg)
    if ratio < CONTRAST_MIN:
        warnings.append(
            f"Contraste bajo ({ratio:.1f}:1, mínimo recomendado {CONTRAST_MIN}:1): "
            "el QR puede no leerse."
        )
    if _luminance(design.fg) > _luminance(design.bg):
        warnings.append(
            "Colores invertidos (módulos más claros que el fondo): "
            "muchos lectores no los leen bien."
        )
    if design.margin < 4:
        warnings.append("Zona de silencio menor a 4 módulos: algunos lectores pueden fallar.")
    if design.logo is not None and design.ecc != "H":
        warnings.append("Con logo se fuerza la corrección de errores H.")
    return warnings


# --------------------------------------------------------------------------- geometría


@dataclass
class _Layout:
    matrix: list[list[int]]
    n: int
    width: float  # unidades (módulos)
    height: float
    ox: float  # origen de la matriz
    oy: float
    corner: float  # radio exterior del marco
    border: float  # grosor del marco (0 = sin marco)
    band: float  # alto de la banda de texto
    logo_box: tuple[float, float, float, float] | None  # x0,y0,x1,y1 en unidades


def _layout(payload: str, design: QrDesign) -> _Layout:
    qr = segno.make(payload, error=design.effective_ecc.lower(), micro=False, boost_error=False)
    matrix = [[int(bool(c)) for c in row] for row in qr.matrix]
    n = len(matrix)
    m = design.margin
    pad = 0 if design.frame == "none" else 2
    inner = n + 2 * m
    width = inner + 2 * pad
    band = 6.0 if design.frame == "label" else 0.0
    logo_box = None
    ox = oy = float(pad + m)
    if design.logo is not None:
        # caja (logo + fondo de seguridad) con lado impar de módulos, ≤ 20 % del área
        side = int(math.sqrt(LOGO_AREA_FRACTION) * n)
        side -= (side + n) % 2  # misma paridad que n → centrada en la rejilla
        c0 = (n - side) / 2
        logo_box = (ox + c0, oy + c0, ox + c0 + side, oy + c0 + side)
    return _Layout(
        matrix=matrix,
        n=n,
        width=float(width),
        height=float(width) + band,
        ox=ox,
        oy=oy,
        corner={"rounded": 2.0, "label": 1.5}.get(design.frame, 0.0),
        border=0.0 if design.frame == "none" else 1.0,
        band=band,
        logo_box=logo_box,
    )


def _is_finder(r: int, c: int, n: int) -> bool:
    return (r < 7 and c < 7) or (r < 7 and c >= n - 7) or (r >= n - 7 and c < 7)


def _in_logo(r: int, c: int, lay: _Layout) -> bool:
    if lay.logo_box is None:
        return False
    x0, y0, x1, y1 = lay.logo_box
    x, y = lay.ox + c, lay.oy + r
    return x + 1 > x0 and x < x1 and y + 1 > y0 and y < y1


def _dark_modules(lay: _Layout) -> Iterator[tuple[int, int]]:
    for r, row in enumerate(lay.matrix):
        for c, v in enumerate(row):
            if v and not _in_logo(r, c, lay):
                yield r, c


def _logo_fit(design: QrDesign, lay: _Layout) -> tuple[Image.Image, tuple[float, float]] | None:
    """Logo escalado para caber en la caja con 1 módulo de fondo de seguridad."""
    if design.logo is None or lay.logo_box is None:
        return None
    im = _load_logo(design.logo)
    x0, y0, x1, y1 = lay.logo_box
    avail = (x1 - x0) - 1.0
    scale = avail / max(im.size)
    w, h = im.width * scale, im.height * scale
    return im, (x0 + ((x1 - x0) - w) / 2, y0 + ((y1 - y0) - h) / 2)


# --------------------------------------------------------------------------- PNG


def render_png(payload: str, design: QrDesign, size: int = 512) -> bytes:
    _check_size(size)
    lay = _layout(payload, design)
    ss = max(1, min(4, MAX_SIZE // size))
    px = size * ss / lay.width  # px por módulo
    w, h = size * ss, round(lay.height * px)
    img = Image.new("RGB", (w, h), design.bg)
    d = ImageDraw.Draw(img)

    if lay.border:
        d.rounded_rectangle((0, 0, w - 1, h - 1), radius=lay.corner * px, fill=design.fg)
        d.rounded_rectangle(
            (px, px, w - 1 - px, lay.width * px - 1),
            radius=max(lay.corner - 1, 0) * px,
            fill=design.bg,
        )
        if lay.band:
            font = ImageFont.load_default(size=max(8, round(2.6 * px)))
            d.text(
                (w / 2, (lay.width + lay.band / 2 - 0.5) * px),
                design.label,
                fill=design.bg,
                font=font,
                anchor="mm",
            )

    r_mod = {"square": 0.0, "rounded": 0.3, "dots": 0.5}[design.module_style]
    for r, c in _dark_modules(lay):
        x0, y0 = (lay.ox + c) * px, (lay.oy + r) * px
        x1, y1 = x0 + px, y0 + px
        rad = 0.0 if _is_finder(r, c, lay.n) else r_mod
        if rad == 0:
            d.rectangle((x0, y0, x1 - 1, y1 - 1), fill=design.fg)
        elif rad >= 0.5:
            d.ellipse((x0, y0, x1 - 1, y1 - 1), fill=design.fg)
        else:
            d.rounded_rectangle((x0, y0, x1 - 1, y1 - 1), radius=rad * px, fill=design.fg)

    fit = _logo_fit(design, lay)
    if fit and lay.logo_box:
        im, (lx, ly) = fit
        bx0, by0, bx1, by1 = lay.logo_box
        d.rectangle((bx0 * px, by0 * px, bx1 * px - 1, by1 * px - 1), fill=design.bg)
        tw = max(1, round(im.width * (lay.logo_box[2] - lay.logo_box[0] - 1) / max(im.size) * px))
        th = max(1, round(im.height * (lay.logo_box[2] - lay.logo_box[0] - 1) / max(im.size) * px))
        scaled = im.resize((tw, th), Image.Resampling.LANCZOS)
        img.paste(scaled, (round(lx * px), round(ly * px)), scaled)

    if ss > 1:
        img = img.resize((size, round(lay.height * size / lay.width)), Image.Resampling.LANCZOS)
    out = io.BytesIO()
    img.save(out, format="PNG", optimize=True)
    return out.getvalue()


# --------------------------------------------------------------------------- SVG


def _f(v: float) -> str:
    return f"{v:.3f}".rstrip("0").rstrip(".")


def _module_path(x: float, y: float, style: str) -> str:
    if style == "square":
        return f"M{_f(x)} {_f(y)}h1v1h-1z"
    if style == "dots":
        return f"M{_f(x + 0.05)} {_f(y + 0.5)}a0.45 0.45 0 1 0 0.9 0a0.45 0.45 0 1 0 -0.9 0z"
    r = 0.3
    s = 1 - 2 * r
    return (
        f"M{_f(x + r)} {_f(y)}h{_f(s)}a{r} {r} 0 0 1 {r} {r}v{_f(s)}a{r} {r} 0 0 1 -{r} {r}"
        f"h-{_f(s)}a{r} {r} 0 0 1 -{r} -{r}v-{_f(s)}a{r} {r} 0 0 1 {r} -{r}z"
    )


def render_svg(payload: str, design: QrDesign) -> str:
    lay = _layout(payload, design)
    w, h = lay.width, lay.height
    parts = [
        '<?xml version="1.0" encoding="UTF-8"?>',
        f'<svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" '
        f'viewBox="0 0 {_f(w)} {_f(h)}" width="{_f(w * 10)}" height="{_f(h * 10)}" '
        'shape-rendering="geometricPrecision">',
        "<title>QR</title>",
    ]
    if lay.border:
        parts.append(
            f'<rect width="{_f(w)}" height="{_f(h)}" rx="{_f(lay.corner)}" fill="{design.fg}"/>'
        )
        parts.append(
            f'<rect x="1" y="1" width="{_f(w - 2)}" height="{_f(w - 1)}" '
            f'rx="{_f(max(lay.corner - 1, 0))}" fill="{design.bg}"/>'
        )
        if lay.band:
            parts.append(
                f'<text x="{_f(w / 2)}" y="{_f(w + lay.band / 2 - 0.5)}" fill="{design.bg}" '
                'font-family="Helvetica, Arial, sans-serif" font-weight="bold" font-size="2.6" '
                f'text-anchor="middle" dominant-baseline="central">{escape(design.label)}</text>'
            )
    else:
        parts.append(f'<rect width="{_f(w)}" height="{_f(h)}" fill="{design.bg}"/>')

    sq: list[str] = []
    st: list[str] = []
    for r, c in _dark_modules(lay):
        x, y = lay.ox + c, lay.oy + r
        if design.module_style == "square" or _is_finder(r, c, lay.n):
            sq.append(_module_path(x, y, "square"))
        else:
            st.append(_module_path(x, y, design.module_style))
    for paths in (sq, st):
        if paths:
            parts.append(f'<path fill="{design.fg}" d="{"".join(paths)}"/>')

    fit = _logo_fit(design, lay)
    if fit and lay.logo_box:
        im, (lx, ly) = fit
        bx0, by0, bx1, by1 = lay.logo_box
        scale = ((bx1 - bx0) - 1.0) / max(im.size)
        buf = io.BytesIO()
        im.save(buf, format="PNG")
        b64 = base64.b64encode(buf.getvalue()).decode()
        parts.append(
            f'<rect x="{_f(bx0)}" y="{_f(by0)}" width="{_f(bx1 - bx0)}" '
            f'height="{_f(by1 - by0)}" fill="{design.bg}"/>'
        )
        parts.append(
            f'<image x="{_f(lx)}" y="{_f(ly)}" width="{_f(im.width * scale)}" '
            f'height="{_f(im.height * scale)}" href="data:image/png;base64,{b64}"/>'
        )
    parts.append("</svg>")
    return "\n".join(parts)


# --------------------------------------------------------------------------- PDF


def render_pdf(payload: str, design: QrDesign, size: int = 1024) -> bytes:
    """PDF de una página con el PNG de alta resolución embebido (no vectorial).

    TODO(T031+): PDF vectorial si se requiere para imprenta.
    """
    _check_size(size)
    png = render_png(payload, design, size)
    with Image.open(io.BytesIO(png)) as im:
        out = io.BytesIO()
        im.convert("RGB").save(out, format="PDF", resolution=max(72.0, size / 4))
    return out.getvalue()
