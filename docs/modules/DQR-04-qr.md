# DQR-04 · Generación y diseño de QR

| Campo | Valor |
|---|---|
| Depende de | DQR-02 |
| Agente líder | qr-nfc |
| Sprint | S2 |
| Tareas | DQR-T030, DQR-T031, DQR-T032, DQR-T033, DQR-T036, DQR-T045, DQR-T065 |

## Alcance
Generación con segno + Pillow (colores, logo, marco, ECC, modos de imagen), descargas PNG/SVG/PDF, plantillas imprimibles y flujo con Canva.

## Criterios de aceptación
- El QR codifica `PUBLIC_REDIRECT_BASE_URL/r/{slug}?c=q`.
- Con logo se usa ECC H; contraste bajo se avisa.
- Diseño por defecto (enlace sin diseño guardado, DQR-T064): logo de Google, módulos en puntos, ojos cuadrados, fondo transparente, margen 4 y ECC H.
- Todo QR generado se decodifica a la URL esperada (test).
- 3 plantillas: sticker, display de mostrador, póster A4; export listo para importar en Canva.
- DQR-T065: `style.image_mode` (`none`, `tint`, `silhouette`, `halftone`, `photo`) reutiliza la imagen de `logo_path` como relleno, sin migración ni endpoints nuevos.
- En modo imagen: ECC H, fondo opaco, logo central desactivado, finder patterns sólidos y zona de silencio limpia; con `image_mode = none` el render limpio no cambia.
- PNG/SVG/PDF de los 4 modos se decodifican en tests; el SVG de modo imagen incrusta el PNG rasterizado (autocontenido).
- Las plantillas imprimibles usan el logo centrado; el modo imagen solo aplica a la descarga QR.

## Archivos esperados
- `apps/api/app/services/qr_render.py`
- `apps/api/app/services/qr_designs.py`
- `apps/api/app/schemas/qr.py`
- `apps/api/app/services/print_templates.py`
- `apps/api/app/routers/qr.py`
- `apps/web/components/qr/qr-designer.tsx`
- `apps/web/components/qr/qr-preview.tsx`
- `apps/web/lib/api.ts`
- `supabase/migrations/*_qr_designs.sql`

## Referencias
- docs/03-modelo-datos.md · docs/04-api.md · AGENTS.md
