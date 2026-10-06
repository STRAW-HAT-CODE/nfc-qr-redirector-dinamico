# DQR-08 · Seguridad y abuso

| Campo | Valor |
|---|---|
| Depende de | DQR-02, DQR-03 |
| Agente líder | security-reviewer |
| Sprint | S4 |
| Tareas | DQR-T050, DQR-T051, DQR-T052, DQR-T057 |

## Alcance
Rate limiting, política de URLs, auditoría, límites y auditoría final.

## Criterios de aceptación
- 429 al superar límites sin afectar tráfico normal.
- Dominios bloqueados rechazados; platform admin suspende enlaces.
- `audit_log` registra cambios de enlaces y miembros.
- Supabase advisors sin errores antes del lanzamiento.

## Archivos esperados
- `apps/api/app/middleware/rate_limit.py`
- `apps/api/app/services/url_policy.py`
- `supabase/migrations/*_audit.sql`
- `docs/06-seguridad.md`

## Referencias
- docs/03-modelo-datos.md · docs/04-api.md · AGENTS.md
