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
from dataclasses import dataclass, replace
from functools import lru_cache
from pathlib import Path
from typing import Literal
from urllib.parse import quote, urlsplit
from xml.sax.saxutils import escape

import segno
from PIL import Image, ImageDraw, ImageEnhance, ImageOps, UnidentifiedImageError

from app.services.qr_fonts import SVG_FAMILY, load_font
from app.services.slug import is_valid_slug

Channel = Literal["q", "n"]
Ecc = Literal["L", "M", "Q", "H"]
Frame = Literal["none", "simple", "rounded", "label"]
ModuleStyle = Literal["square", "rounded", "dots"]
ImageMode = Literal["none", "tint", "silhouette", "halftone", "photo"]

MIN_SIZE = 128
MAX_SIZE = 4096
MAX_LOGO_BYTES = 1_000_000
MAX_LOGO_PIXELS = 4_000_000  # anti decompression bomb
MAX_LABEL_LEN = 30
LOGO_AREA_FRACTION = 0.20
CONTRAST_MIN = 4.5
# Luminancia mínima de una celda clara en modo imagen. Por debajo se aclara con `bg`.
IMAGE_LIGHT_MIN = 0.62

_HEX_RE = re.compile(r"^#(?:[0-9a-fA-F]{3}|[0-9a-fA-F]{6})$")
_TAG_RE = re.compile(r"^[A-Za-z0-9_-]{1,64}$")
_LOGO_FORMATS = {"PNG", "JPEG", "WEBP"}
_ECC_LEVELS = ("L", "M", "Q", "H")
_FRAMES = ("none", "simple", "rounded", "label")
_STYLES = ("square", "rounded", "dots")
_IMAGE_MODES = ("none", "tint", "silhouette", "halftone", "photo")


class QrRenderError(ValueError):
    """Entrada inválida para la generación de QR."""


# Logos incluidos en el repo (DQR-T060). Lista blanca: el nombre nunca es una ruta.
LOGO_PRESETS: dict[str, str] = {"google": "google-g-1024.png"}
_ASSETS = Path(__file__).resolve().parent.parent / "assets" / "logos"


@lru_cache(maxsize=8)
def preset_logo(name: str) -> bytes:
    """Bytes PNG del logo de un preset (`google`). Nombre fuera de la lista blanca → error."""
    fname = LOGO_PRESETS.get(name) if isinstance(name, str) else None
    if fname is None:
        raise QrRenderError("logo_preset inválido")
    try:
        data = (_ASSETS / fname).read_bytes()
    except OSError:
        raise QrRenderError("asset del preset no disponible") from None
    _load_logo(data)  # valida
    return data


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
    # PNG RGBA / SVG sin fondo; el PDF mantiene blanco (formato de impresión). `bg` sigue siendo
    # el color de referencia (contraste y texto del marco).
    bg_transparent: bool = False
    # DQR-T065: la imagen subida (`logo`) se usa como relleno del QR. `none` conserva el logo
    # centrado de siempre. En modo imagen se fuerza ECC H y fondo opaco.
    image_mode: ImageMode = "none"
    image_intensity: float = 0.8
    image_contrast: float = 1.0

    def __post_init__(self) -> None:
        object.__setattr__(self, "fg", _norm_hex(self.fg, "fg"))
        object.__setattr__(self, "bg", _norm_hex(self.bg, "bg"))
        if self.ecc not in _ECC_LEVELS:
            raise QrRenderError("ecc inválido")
        if self.frame not in _FRAMES:
            raise QrRenderError("frame inválido")
        if self.module_style not in _STYLES:
            raise QrRenderError("module_style inválido")
        if self.image_mode not in _IMAGE_MODES:
            raise QrRenderError("image_mode inválido")
        if not isinstance(self.bg_transparent, bool):
            raise QrRenderError("bg_transparent debe ser booleano")
        if not isinstance(self.margin, int) or not 0 <= self.margin <= 16:
            raise QrRenderError("margin debe estar entre 0 y 16 módulos")
        if (
            isinstance(self.image_intensity, bool)
            or not isinstance(self.image_intensity, int | float)
            or not 0.0 <= float(self.image_intensity) <= 1.0
        ):
            raise QrRenderError("image_intensity debe estar entre 0 y 1")
        if (
            isinstance(self.image_contrast, bool)
            or not isinstance(self.image_contrast, int | float)
            or not 0.5 <= float(self.image_contrast) <= 2.0
        ):
            raise QrRenderError("image_contrast debe estar entre 0.5 y 2")
        if self.frame_text is not None and (
            len(self.frame_text) > MAX_LABEL_LEN
            or any(ord(c) < 32 or ord(c) == 127 for c in self.frame_text)
        ):
            raise QrRenderError("frame_text inválido")
        if self.logo is not None:
            _load_logo(self.logo)  # valida

    @property
    def effective_ecc(self) -> Ecc:
        return "H" if self.logo is not None or self.image_mode != "none" else self.ecc

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


def check_design(design: QrDesign, has_logo: bool | None = None) -> list[str]:
    """Avisos (no bloqueantes) sobre legibilidad.

    `has_logo` permite indicar que hay logo sin cargar sus bytes; por defecto `design.logo`.
    """
    if has_logo is None:
        has_logo = design.logo is not None
    warnings: list[str] = []
    transparent = design.bg_transparent and design.image_mode == "none"
    if transparent:
        warnings.append("Fondo transparente: colócalo sobre una superficie clara")
    # con fondo transparente el contraste se calcula contra blanco
    ratio = contrast_ratio(design.fg, "#ffffff" if transparent else design.bg)
    if ratio < CONTRAST_MIN:
        warnings.append(
            f"Contraste bajo ({ratio:.1f}:1, mínimo recomendado {CONTRAST_MIN}:1): "
            "el QR puede no leerse."
        )
    ref_bg = "#ffffff" if transparent else design.bg
    if _luminance(design.fg) > _luminance(ref_bg):
        warnings.append(
            "Colores invertidos (módulos más claros que el fondo): "
            "muchos lectores no los leen bien."
        )
    if design.margin < 4:
        warnings.append("Zona de silencio menor a 4 módulos: algunos lectores pueden fallar.")
    if has_logo and design.ecc != "H":
        warnings.append("Con logo se fuerza la corrección de errores H.")
    if design.image_mode != "none":
        if not has_logo:
            warnings.append("Modo imagen sin imagen: sube un logo o imagen.")
        else:
            warnings.append(
                "Modo imagen: la foto reduce el contraste; escanea el QR en su tamaño final."
            )
        if design.bg_transparent:
            warnings.append("En modo imagen el fondo se fuerza opaco para conservar el contraste.")
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
    if design.logo is not None and design.image_mode == "none":
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


def _image_on(design: QrDesign) -> bool:
    """Modo imagen solo si hay una imagen subida; sin ella se conserva el QR limpio."""
    return design.image_mode != "none" and design.logo is not None


def _draw_module(
    d: ImageDraw.ImageDraw,
    x0: float,
    y0: float,
    px: float,
    style: str,
    fill: tuple[int, int, int] | str,
    radius: float | None = None,
) -> None:
    x1, y1 = x0 + px, y0 + px
    if radius is not None:  # halftone: punto de radio variable centrado en el módulo
        cx, cy = x0 + px / 2, y0 + px / 2
        r = max(0.5, radius * px)
        d.ellipse((cx - r, cy - r, cx + r, cy + r), fill=fill)
    elif style == "square":
        d.rectangle((x0, y0, x1 - 1, y1 - 1), fill=fill)
    elif style == "dots":
        d.ellipse((x0, y0, x1 - 1, y1 - 1), fill=fill)
    else:
        d.rounded_rectangle((x0, y0, x1 - 1, y1 - 1), radius=0.3 * px, fill=fill)


def _luma(img: Image.Image, x: int, y: int) -> float:
    """Luminancia 0..1 de un píxel (la imagen intermedia siempre es L)."""
    value = img.getpixel((x, y))
    if isinstance(value, tuple):
        return value[0] / 255.0
    if isinstance(value, int | float):
        return float(value) / 255.0
    return 0.0


def _rgb_at(img: Image.Image, x: int, y: int) -> tuple[int, int, int]:
    value = img.getpixel((x, y))
    if isinstance(value, tuple) and len(value) >= 3:
        return int(value[0]), int(value[1]), int(value[2])
    return 0, 0, 0


def _paint_image_qr(img: Image.Image, lay: _Layout, design: QrDesign, px: float) -> Image.Image:
    """Pinta el QR sobre la imagen: relleno, celdas claras aclaradas y módulos oscuros encima.

    `tint` muestrea la imagen por módulo y mezcla cada celda con `fg`/`bg` (mosaico); el resto
    pega la imagen y aclara las celdas claras que no tengan luminancia suficiente.
    """
    if design.logo is None:  # defensa: `_image_on` ya lo comprueba
        return img
    n = lay.n
    src = ImageEnhance.Contrast(_load_logo(design.logo)).enhance(float(design.image_contrast))
    if design.image_mode == "silhouette":
        threshold = 96 + 64 * float(design.image_intensity)
        src = src.convert("L").point(lambda v: 255 if v >= threshold else 0).convert("RGBA")
    area = max(1, round(n * px))
    src = ImageOps.fit(src, (area, area), method=Image.Resampling.LANCZOS, centering=(0.5, 0.5))
    small = src.convert("L").resize((n, n), Image.Resampling.BOX)
    x0m, y0m = round(lay.ox * px), round(lay.oy * px)
    d = ImageDraw.Draw(img)

    if design.image_mode == "tint":
        small_rgb = src.convert("RGB").resize((n, n), Image.Resampling.BOX)
        intensity = float(design.image_intensity)
        dark_mix, light_mix = 0.55 + 0.35 * intensity, 0.72 + 0.20 * intensity
        for r in range(n):
            for c in range(n):
                x0, y0 = x0m + c * px, y0m + r * px
                if _is_finder(r, c, n):  # finder sólido: negro en módulos, `bg` en separadores
                    _draw_module(
                        d, x0, y0, px, "square", design.fg if lay.matrix[r][c] else design.bg
                    )
                    continue
                sample = _rgb_at(small_rgb, c, r)
                dark = bool(lay.matrix[r][c])
                target = _rgb(design.fg) if dark else _rgb(design.bg)
                mix = dark_mix if dark else light_mix
                fill = (
                    round(sample[0] * (1 - mix) + target[0] * mix),
                    round(sample[1] * (1 - mix) + target[1] * mix),
                    round(sample[2] * (1 - mix) + target[2] * mix),
                )
                _draw_module(d, x0, y0, px, design.module_style, fill)
        return img

    img.paste(src, (x0m, y0m), src)
    overlay = Image.new("RGBA", img.size, (0, 0, 0, 0))
    od = ImageDraw.Draw(overlay)
    base_alpha = {"silhouette": 0.55, "halftone": 0.40, "photo": 0.30}.get(design.image_mode, 0.40)
    intensity = float(design.image_intensity)
    for r in range(n):
        for c in range(n):
            if lay.matrix[r][c]:
                continue
            x0, y0 = x0m + c * px, y0m + r * px
            if _is_finder(r, c, n):  # separador del finder: siempre `bg` limpio
                od.rectangle((x0, y0, x0 + px - 1, y0 + px - 1), fill=(*_rgb(design.bg), 255))
                continue
            lum = _luma(small, c, r)
            if lum >= IMAGE_LIGHT_MIN:
                continue
            alpha = min(0.92, base_alpha + (IMAGE_LIGHT_MIN - lum) * 1.2)
            alpha *= 0.65 + 0.35 * intensity
            od.rectangle(
                (x0, y0, x0 + px - 1, y0 + px - 1),
                fill=(*_rgb(design.bg), round(alpha * 255)),
            )
    img = Image.alpha_composite(img.convert("RGBA"), overlay).convert("RGB")
    d = ImageDraw.Draw(img)
    for r in range(n):
        for c in range(n):
            if not lay.matrix[r][c]:
                continue
            x0, y0 = x0m + c * px, y0m + r * px
            if _is_finder(r, c, n):
                _draw_module(d, x0, y0, px, "square", design.fg)
            elif design.image_mode == "halftone":
                lum = _luma(small, c, r)
                _draw_module(d, x0, y0, px, "dots", design.fg, radius=0.34 + 0.16 * (1 - lum))
            else:
                _draw_module(d, x0, y0, px, design.module_style, design.fg)
    return img


def render_png(payload: str, design: QrDesign, size: int = 512) -> bytes:
    _check_size(size)
    lay = _layout(payload, design)
    ss = max(1, min(4, MAX_SIZE // size))
    px = size * ss / lay.width  # px por módulo
    w, h = size * ss, round(lay.height * px)
    image_on = _image_on(design)
    # En modo imagen el fondo se fuerza opaco: la imagen necesita un fondo sólido.
    transp = design.bg_transparent and not image_on
    bg_fill: tuple[int, ...] | str = (*_rgb(design.bg), 0) if transp else design.bg
    img = Image.new("RGBA" if transp else "RGB", (w, h), bg_fill)
    d = ImageDraw.Draw(img)

    if lay.border:
        d.rounded_rectangle((0, 0, w - 1, h - 1), radius=lay.corner * px, fill=design.fg)
        d.rounded_rectangle(
            (px, px, w - 1 - px, lay.width * px - 1),
            radius=max(lay.corner - 1, 0) * px,
            fill=bg_fill,  # ImageDraw sobrescribe (no mezcla): con RGBA deja el hueco alfa 0
        )
        if lay.band:
            font = load_font(max(8, round(2.6 * px)))
            d.text(
                (w / 2, (lay.width + lay.band / 2 - 0.5) * px),
                design.label,
                fill=design.bg,
                font=font,
                anchor="mm",
            )

    if image_on:
        img = _paint_image_qr(img, lay, design, px)
    else:
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
            d.rectangle((bx0 * px, by0 * px, bx1 * px - 1, by1 * px - 1), fill=bg_fill)
            avail = lay.logo_box[2] - lay.logo_box[0] - 1
            tw = max(1, round(im.width * avail / max(im.size) * px))
            th = max(1, round(im.height * avail / max(im.size) * px))
            scaled = im.resize((tw, th), Image.Resampling.LANCZOS)
            if transp:  # componer sobre capa transparente: el alfa del logo se conserva
                layer = Image.new("RGBA", img.size, (0, 0, 0, 0))
                layer.paste(scaled, (round(lx * px), round(ly * px)))
                img = Image.alpha_composite(img, layer)
            else:
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


def _rrect_path(x: float, y: float, w: float, h: float, r: float) -> str:
    r = min(r, w / 2, h / 2)
    if r <= 0:
        return f"M{_f(x)} {_f(y)}h{_f(w)}v{_f(h)}h-{_f(w)}z"
    return (
        f"M{_f(x + r)} {_f(y)}h{_f(w - 2 * r)}a{_f(r)} {_f(r)} 0 0 1 {_f(r)} {_f(r)}"
        f"v{_f(h - 2 * r)}a{_f(r)} {_f(r)} 0 0 1 -{_f(r)} {_f(r)}"
        f"h-{_f(w - 2 * r)}a{_f(r)} {_f(r)} 0 0 1 -{_f(r)} -{_f(r)}"
        f"v-{_f(h - 2 * r)}a{_f(r)} {_f(r)} 0 0 1 {_f(r)} -{_f(r)}z"
    )


def svg_body(lay: _Layout, design: QrDesign) -> list[str]:
    """Elementos SVG del QR (marco, módulos, logo) en unidades de módulo, sin `<svg>` envolvente.

    Compartido por `render_svg` y las plantillas imprimibles (print_templates). El texto del
    marco usa `y` de línea base (sin `dominant-baseline`) para importarse bien en Canva.
    """
    w, h = lay.width, lay.height
    parts: list[str] = []
    transp = design.bg_transparent
    if lay.border and transp:
        # marco con hueco real (evenodd): sin rect de fondo
        parts.append(
            f'<path fill="{design.fg}" fill-rule="evenodd" d="'
            f"{_rrect_path(0, 0, w, h, lay.corner)}"
            f'{_rrect_path(1, 1, w - 2, w - 1, max(lay.corner - 1, 0))}"/>'
        )
    elif lay.border:
        parts.append(
            f'<rect width="{_f(w)}" height="{_f(h)}" rx="{_f(lay.corner)}" fill="{design.fg}"/>'
        )
        parts.append(
            f'<rect x="1" y="1" width="{_f(w - 2)}" height="{_f(w - 1)}" '
            f'rx="{_f(max(lay.corner - 1, 0))}" fill="{design.bg}"/>'
        )
    if lay.border:
        if lay.band:
            parts.append(
                f'<text x="{_f(w / 2)}" y="{_f(w + lay.band / 2 - 0.5 + 0.9)}" fill="{design.bg}" '
                f'font-family="{SVG_FAMILY}" font-weight="bold" font-size="2.6" '
                f'text-anchor="middle">{escape(design.label)}</text>'
            )
    elif not transp:
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
        if not transp:
            parts.append(
                f'<rect x="{_f(bx0)}" y="{_f(by0)}" width="{_f(bx1 - bx0)}" '
                f'height="{_f(by1 - by0)}" fill="{design.bg}"/>'
            )
        parts.append(
            f'<image x="{_f(lx)}" y="{_f(ly)}" width="{_f(im.width * scale)}" '
            f'height="{_f(im.height * scale)}" href="data:image/png;base64,{b64}"/>'
        )
    return parts


def render_svg(payload: str, design: QrDesign) -> str:
    lay = _layout(payload, design)
    w, h = lay.width, lay.height
    if _image_on(design):
        # El modo imagen se rasteriza (y se incrusta como PNG): reproduce el render exacto y
        # mantiene el SVG autocontenido. El QR limpio sigue siendo vectorial.
        png = render_png(payload, design, size=2048)
        b64 = base64.b64encode(png).decode()
        return "\n".join(
            [
                '<?xml version="1.0" encoding="UTF-8"?>',
                f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {_f(w)} {_f(h)}" '
                f'width="{_f(w * 10)}" height="{_f(h * 10)}">',
                "<title>QR</title>",
                f'<image width="{_f(w)}" height="{_f(h)}" href="data:image/png;base64,{b64}"/>',
                "</svg>",
            ]
        )
    head = [
        '<?xml version="1.0" encoding="UTF-8"?>',
        f'<svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" '
        f'viewBox="0 0 {_f(w)} {_f(h)}" width="{_f(w * 10)}" height="{_f(h * 10)}" '
        'shape-rendering="geometricPrecision">',
        "<title>QR</title>",
    ]
    return "\n".join([*head, *svg_body(lay, design), "</svg>"])


# --------------------------------------------------------------------------- PDF


def render_pdf(payload: str, design: QrDesign, size: int = 1024) -> bytes:
    """PDF de una página con el PNG de alta resolución embebido (no vectorial).

    Formato de impresión: con `bg_transparent` el PDF mantiene fondo blanco.

    TODO(T031+): PDF vectorial si se requiere para imprenta.
    """
    _check_size(size)
    png = render_png(
        payload,
        replace(design, bg_transparent=False, bg="#ffffff") if design.bg_transparent else design,
        size,
    )
    with Image.open(io.BytesIO(png)) as im:
        out = io.BytesIO()
        im.convert("RGB").save(out, format="PDF", resolution=max(72.0, size / 4))
    return out.getvalue()
