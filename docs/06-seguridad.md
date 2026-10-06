# 6 · Seguridad, abuso, eventos y métricas

## Amenazas y controles
| Amenaza | Control |
|---|---|
| Fuga de datos entre clientes | `org_id` + RLS en todo; tests SQL de aislamiento; la API usa el JWT del usuario |
| Open redirect | `/r` solo redirige a URLs guardadas; nunca a parámetros de la query |
| Destinos maliciosos (phishing) | Solo http/https; blocklist; platform admin puede suspender |
| Abuso / scraping de `/r` | Rate limit por IP; bots marcados `is_bot` |
| Enumeración de slugs | Slug base62 de 7 caracteres aleatorio |
| Escalada de rol | Cambios de rol solo admin/owner; no se puede quitar el último owner |
| Secretos expuestos | Solo variables de entorno; service role solo en servidor |
| Privacidad | IP hasheada con sal rotativa; sin cookies en `/r` |
| Cambios no rastreados | `audit_log` + `link_destination_history` |

## Eventos y métricas
- Evento `scan`: link, org, canal, tag, fecha, país (header de la plataforma), dispositivo/SO/navegador (User-Agent), referer, ip_hash, is_bot.
- Métricas: totales, únicos (ip_hash + UA por día), por día, canal, país y dispositivo. Bots excluidos.
- Rollups diarios (`scan_daily_rollups`) con pg_cron.

## Revisiones
security-reviewer aprueba toda migración y registra hallazgos aquí.

| Fecha | Tarea | Hallazgo | Estado |
|---|---|---|---|
| — | — | — | — |
