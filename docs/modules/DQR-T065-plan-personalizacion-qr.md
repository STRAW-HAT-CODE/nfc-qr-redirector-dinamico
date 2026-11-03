# DQR-T065 · QR artístico (implementación final)

| Campo | Valor |
|---|---|
| Rama | `feat/DQR-T065-qr-artistic-customization` |
| Estado | Implementado; pendiente PR y revisión |
| Migraciones | Ninguna |

## Alcance final

- Reutiliza `qr_designs.logo_path` (bucket `logos`, PNG ≤ 1 MB) como imagen.
- `style.image_mode`: `none`, `tint`, `silhouette`, `halftone`, `photo`.
- `style.image_intensity` (0–1) y `style.image_contrast` (0.5–2).
- `none`: logo centrado de siempre; el render limpio no cambia.
- Modo imagen: ECC H, fondo opaco, sin logo central, finder patterns sólidos y zona de
  silencio limpia.
- PNG/PDF raster; el SVG de modo imagen incrusta un PNG de 2048 px (autocontenido). El QR
  limpio sigue siendo vectorial.
- Plantillas imprimibles: logo centrado; no rasterizan la imagen.

## Contrato

`PUT /v1/links/{id}/design` con `style.image_mode`. Ver `docs/04-api.md`.

## Verificación

- `uv run pytest tests/test_qr_render.py tests/test_qr_api.py` (matriz de decodificación).
- `pnpm lint`, `pnpm test`, `pnpm build`.
- Smoke manual: subir imagen, elegir halftone, guardar, descargar PNG/SVG y escanear.

## Descartado para v1

- Formas de ojos independientes, colores bicolor del finder y stickers die-cut: más
  superficie de render y no son necesarios para el objetivo.
- `logo_mode` separado: se cubre con `image_mode`.
- Migración SQL: el `style` JSONB existente basta.
- SVG vectorial en modo imagen: se rasteriza para reproducir la composición exacta; el QR
  limpio sigue vectorial.
