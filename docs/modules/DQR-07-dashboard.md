# DQR-07 · Dashboard web

| Campo | Valor |
|---|---|
| Depende de | DQR-01, DQR-02 |
| Agente líder | frontend |
| Sprint | S3 |
| Tareas | DQR-T043, DQR-T044, DQR-T045, DQR-T046, DQR-T047, DQR-T048, DQR-T049 |

## Alcance
Next.js + shadcn: auth, selector de org, enlaces, diseñador QR, NFC, analytics, miembros.

## Criterios de aceptación
- Todas las pantallas de docs/05-pantallas.md con estados vacío/carga/error.
- Permisos por rol reflejados en la UI.
- E2E: crear enlace → descargar QR → escanear → ver métrica → cambiar destino.

## Archivos esperados
- `apps/web/app/(auth)/`
- `apps/web/app/(app)/`
- `apps/web/e2e/`

## Referencias
- docs/03-modelo-datos.md · docs/04-api.md · AGENTS.md
