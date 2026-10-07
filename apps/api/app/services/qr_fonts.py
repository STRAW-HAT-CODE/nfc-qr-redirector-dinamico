"""Fuente incluida en el repo (Noto Sans, OFL; subconjunto latino) para PNG, PDF y SVG.

El entorno serverless no garantiza fuentes con glifos latinos (¿, ó, é, ñ): se usa siempre
este TTF de `app/assets/fonts/` (ver LICENSE-OFL.txt), nunca la fuente por defecto de Pillow.
"""

from __future__ import annotations

from functools import lru_cache
from pathlib import Path

from PIL import ImageFont

FONT_DIR = Path(__file__).resolve().parent.parent / "assets" / "fonts"
BOLD_FILE = FONT_DIR / "NotoSans-Bold.ttf"
SVG_FAMILY = "'Noto Sans', Helvetica, Arial, sans-serif"
PDF_FONT_NAME = "NotoSans-Bold"


@lru_cache(maxsize=1)
def bold_bytes() -> bytes:
    return BOLD_FILE.read_bytes()


@lru_cache(maxsize=64)
def load_font(size: int) -> ImageFont.FreeTypeFont:
    """Noto Sans Bold a `size` px (siempre TrueType, nunca `load_default`)."""
    return ImageFont.truetype(str(BOLD_FILE), size=max(1, size))


@lru_cache(maxsize=1)
def _metric_font() -> ImageFont.FreeTypeFont:
    return ImageFont.truetype(str(BOLD_FILE), size=1000)


@lru_cache(maxsize=512)
def glyph_width(ch: str) -> float:
    """Ancho del carácter en 1/1000 em."""
    return float(_metric_font().getlength(ch))


def string_width(s: str, size: float) -> float:
    """Ancho de `s` a `size` (misma unidad que `size`)."""
    return sum(glyph_width(c) for c in s) / 1000 * size


def pdf_font_objects(file_obj: int) -> list[bytes]:
    """Objetos PDF (Font, FontDescriptor, FontFile2) de la fuente incrustada.

    `file_obj` es el nº del FontFile2; el descriptor debe ser el objeto `file_obj - 1`.
    Codificación WinAnsi (cp1252), anchos tomados de la propia fuente.
    """
    import zlib

    widths = " ".join(
        str(round(glyph_width(bytes([c]).decode("cp1252", "replace")))) for c in range(32, 256)
    )
    data = zlib.compress(bold_bytes())
    font = (
        f"<< /Type /Font /Subtype /TrueType /BaseFont /{PDF_FONT_NAME} "
        f"/Encoding /WinAnsiEncoding /FirstChar 32 /LastChar 255 /Widths [{widths}] "
        f"/FontDescriptor {file_obj - 1} 0 R >>"
    ).encode()
    desc = (
        f"<< /Type /FontDescriptor /FontName /{PDF_FONT_NAME} /Flags 32 "
        "/FontBBox [-600 -300 1400 1100] /ItalicAngle 0 /Ascent 1069 /Descent -293 "
        f"/CapHeight 714 /StemV 140 /FontFile2 {file_obj} 0 R >>"
    ).encode()
    stream = (
        (
            f"<< /Length {len(data)} /Length1 {len(bold_bytes())} /Filter /FlateDecode >>\nstream\n"
        ).encode()
        + data
        + b"\nendstream"
    )
    return [font, desc, stream]
