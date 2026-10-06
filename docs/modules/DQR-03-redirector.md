# DQR-03 · Redirector

| Campo | Valor |
|---|---|
| Depende de | DQR-02 |
| Agente líder | backend-api |
| Sprint | S1 |
| Tareas | DQR-T021, DQR-T022, DQR-T023, DQR-T024, DQR-T015 |

## Alcance
`GET /r/{slug}`: resuelve el enlace y responde 302 con `Cache-Control: no-store`; fallback; registro asíncrono del escaneo con canal.

## Criterios de aceptación
- p95 < 150 ms con registro activo.
- Error al registrar nunca rompe la redirección.
- Pausado/vencido → fallback o página no disponible; inexistente → 404 amable.
- Nunca 301; nunca redirige a URLs de la query.

## Archivos esperados
- `apps/api/app/routers/redirect.py`
- `apps/api/app/services/scan_logger.py`
- `supabase/migrations/*_scan_events.sql`

## Referencias
- docs/03-modelo-datos.md · docs/04-api.md · AGENTS.md
