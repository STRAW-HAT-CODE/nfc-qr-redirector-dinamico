# DQR-05 · NFC

| Campo | Valor |
|---|---|
| Depende de | DQR-02, DQR-03 |
| Agente líder | qr-nfc |
| Sprint | S2 |
| Tareas | DQR-T034, DQR-T035, DQR-T046 |

## Alcance
Etiquetas NFC por enlace con ubicación; URL NDEF `…/r/{slug}?c=n&t={tag}`; guía de grabado.

## Criterios de aceptación
- La URL cabe en NTAG213 (144 bytes).
- Escaneos NFC aparecen con canal `nfc` y su tag.
- Guía para grabar con apps estándar en iOS y Android.

## Archivos esperados
- `supabase/migrations/*_nfc_tags.sql`
- `apps/api/app/routers/nfc.py`

## Referencias
- docs/03-modelo-datos.md · docs/04-api.md · AGENTS.md
