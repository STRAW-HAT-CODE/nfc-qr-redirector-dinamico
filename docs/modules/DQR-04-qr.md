# DQR-04 · Generación y diseño de QR

| Campo | Valor |
|---|---|
| Depende de | DQR-02 |
| Agente líder | qr-nfc |
| Sprint | S2 |
| Tareas | DQR-T030, DQR-T031, DQR-T032, DQR-T033, DQR-T036, DQR-T045 |

## Alcance
Generación con segno + Pillow (colores, logo, marco, ECC), descargas PNG/SVG/PDF, plantillas imprimibles y flujo con Canva.

## Criterios de aceptación
- El QR codifica `PUBLIC_REDIRECT_BASE_URL/r/{slug}?c=q`.
- Con logo se usa ECC H; contraste bajo se avisa.
- Diseño por defecto (enlace sin diseño guardado, DQR-T064): logo de Google, módulos en puntos, ojos cuadrados, fondo transparente, margen 4 y ECC H.
- Todo QR generado se decodifica a la URL esperada (test).
- 3 plantillas: sticker, display de mostrador, póster A4; export listo para importar en Canva.

## Archivos esperados
- `apps/api/app/services/qr_render.py`
- `apps/api/app/services/print_templates.py`
- `apps/api/app/routers/qr.py`
- `supabase/migrations/*_qr_designs.sql`

## Referencias
- docs/03-modelo-datos.md · docs/04-api.md · AGENTS.md
