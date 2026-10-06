# DQR-06 · Analytics

| Campo | Valor |
|---|---|
| Depende de | DQR-03 |
| Agente líder | analytics |
| Sprint | S3 |
| Tareas | DQR-T040, DQR-T041, DQR-T042, DQR-T047 |

## Alcance
Enriquecimiento de eventos (UA, país, dispositivo, bots), rollups diarios con pg_cron y endpoints de métricas.

## Criterios de aceptación
- Bots excluidos de métricas.
- `group=day|channel|country|device` con rango de fechas.
- Consultas de 90 días < 200 ms usando rollups.

## Archivos esperados
- `apps/api/app/services/scan_enrich.py`
- `supabase/migrations/*_rollups.sql`
- `apps/api/app/routers/stats.py`

## Referencias
- docs/03-modelo-datos.md · docs/04-api.md · AGENTS.md
