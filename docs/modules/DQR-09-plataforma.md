# DQR-09 · Consola de plataforma Monky

| Campo | Valor |
|---|---|
| Depende de | DQR-01 |
| Agente líder | frontend |
| Sprint | S4 |
| Tareas | DQR-T053, DQR-T054 |

## Alcance
Vista para platform admins: clientes, planes y límites, suspensión, uso global.

## Criterios de aceptación
- Solo `platform_admins` acceden (API y UI).
- Superar límites del plan devuelve error claro.
- Acciones auditadas.

## Archivos esperados
- `supabase/migrations/*_plans.sql`
- `apps/api/app/services/limits.py`
- `apps/api/app/routers/admin.py`
- `apps/web/app/(platform)/`

## Referencias
- docs/03-modelo-datos.md · docs/04-api.md · AGENTS.md
