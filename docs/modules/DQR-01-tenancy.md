# DQR-01 · Identidad y tenancy

| Campo | Valor |
|---|---|
| Depende de | DQR-00 |
| Agente líder | db-architect |
| Sprint | S1 |
| Tareas | DQR-T013, DQR-T014, DQR-T016, DQR-T017, DQR-T048 |

## Alcance
Supabase Auth, organizaciones, membresías con roles owner/admin/editor/viewer, platform admins, helpers RLS y API de orgs/miembros.

## Criterios de aceptación
- Usuario de org A no puede leer ni escribir nada de org B (tests SQL).
- Crear org convierte al creador en owner; no se puede quitar el último owner.
- API: 401 sin token, 403 sin membresía o rol insuficiente.

## Archivos esperados
- `supabase/migrations/*_tenancy.sql`
- `supabase/tests/tenancy_test.sql`
- `apps/api/app/auth.py`
- `apps/api/app/deps.py`
- `apps/api/app/routers/orgs.py`

## Referencias
- docs/03-modelo-datos.md · docs/04-api.md · AGENTS.md
