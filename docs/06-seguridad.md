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
| 2026-10-05 | DQR-T013 | H1 MEDIA: el trigger del último owner permitía 0 owners en REPEATABLE READ → ahora se rechaza en RR (0A000) | Resuelto (6d560b4) |
| 2026-10-05 | DQR-T013 | H2 MEDIA: faltaban tests (escritura en platform_admins, join ajeno no owner, anon, editor, inmutables) → plan(66) | Resuelto (6d560b4) |
| 2026-10-05 | DQR-T013 | H3 BAJA: memberships.created_at falsificable → grant de INSERT por columnas | Resuelto (6d560b4) |
| 2026-10-05 | DQR-T013 | H4 BAJA: borrar en Auth al último owner falla → definir el flujo (transferir o borrar la org) | Backlog / product |
| 2026-10-05 | DQR-T013 | H5 BAJA: create_organization sin límite por usuario (RPC expuesta en PostgREST) | Backlog / product |
| 2026-10-05 | DQR-T013 | H6 BAJA: un admin podía cambiar el slug de la org → inmutable salvo platform admin o service role | Resuelto (6d560b4) |
| 2026-10-05 | DQR-T013 | H7 INFO: organizations_guard depende de current_user; ninguna RPC SECURITY DEFINER debe escribir plan/status/limits/slug desde la entrada del usuario | Info |
| 2026-10-05 | DQR-T013 | H8 INFO: "Invitar" (docs/04) frente a añadir directamente un user_id; el error de FK revela si un UUID existe → DQR-T016 | Info |
| 2026-10-05 | DQR-T013 | H9 INFO: org suspendida sin efecto en la RLS de tenancy → definir en DQR-09 | Info |
| 2026-10-05 | DQR-T018 | H1 ALTA: un slug borrado se podía reasignar a otra org (secuestro de QR/NFC impresos) → `private.slug_registry` + trigger; nunca se reasigna, tampoco por service_role | Resuelto (738a1b3) |
| 2026-10-05 | DQR-T018 | H2 BAJA: las URLs aceptaban caracteres de control (\x01–\x1f, \x7f) → `!~ '[[:cntrl:]]'` en destino y fallback | Resuelto (738a1b3) |
| 2026-10-05 | DQR-T018 | H3 MEDIA: url_policy, el slug aleatorio y la blocklist se podían saltar escribiendo directo en PostgREST → ADR-0006: slug generado en BD (`gen_slug`, sin grant de INSERT sobre slug), `is_safe_url` y `blocked_domains` en BD. Sondas: userinfo, IPv4 legacy (decimal/hex/octal/corta), IPv6 mapeada/NAT64/ULA/link-local, mayúsculas, puntos finales, IDN sin punycode y puntos fullwidth → rechazados | Resuelto (738a1b3) |
| 2026-10-05 | DQR-T018 | H8 BAJA: bloquear un dominio no afecta a los enlaces que ya apuntan a él (`resolve_link` los sigue devolviendo) → comprobar `url_is_blocked` al resolver o barrido + suspensión | Backlog / DQR-08 |
| 2026-10-05 | DQR-T018 | H4 INFO: no hay estado "suspendido" de enlace solo para platform admin (un editor reactiva un paused) | Backlog / DQR-08-09 |
| 2026-10-05 | DQR-T018 | H5 INFO: T021 decide con los datos crudos de `resolve_link` → tests de archived/paused/no iniciado/vencido/org suspendida; percent-encode de Location; definir el comportamiento de un enlace archivado | Info / T021 · product |
| 2026-10-05 | DQR-T018 | H6 INFO: el DELETE real borra el historial en cascada → audit_log (T052) debe registrar el borrado con el último destino | Info / T052 |
| 2026-10-05 | DQR-T018 | H7 INFO: oráculo de existencia de slug (23505, aceptable); hosts con DNS a loopback (`*.nip.io`) aceptados (sin impacto mientras nada haga fetch del destino); `gen_slug`/`is_safe_url` ejecutables por authenticated (`private` no está expuesto en la Data API); `resolve_link` podría ser SECURITY INVOKER | Info |
| 2026-10-05 | DQR-T022 | H1 BAJA: `tag_id` sin validar (viene de `?t=` y lo controla el atacante); romperá la FK de T034 → T023 no lo pasa hasta T034; T034: FK compuesta (tag_id, link_id) NOT VALID + limpieza + VALIDATE | Backlog / T023 · T034 |
| 2026-10-05 | DQR-T022 | H2 BAJA: `scan_clip` deja pasar caracteres de formato Unicode (U+202E, U+200B, U+2028, U+FEFF, NBSP) → regex ampliada y espacios normalizados | Resuelto (migración `20261006024532_scan_clip_hardening`) |
| 2026-10-05 | DQR-T022 | H3 INFO: el saneado aplica la regex a toda la entrada (5 MB = 0,68 s) → `left(p, p_max*4)` antes | Resuelto (migración `20261006024532_scan_clip_hardening`) |
| 2026-10-05 | DQR-T022 | H4 BAJA: se guarda el referer completo con query (PII/tokens) → guardar solo el origen; el frontend no lo pinta como href | Backlog / T023 · T040 |
| 2026-10-05 | DQR-T022 | H5 INFO: el CHECK de ip_hash no distingue una IPv6 en hex → HMAC-SHA256 (64 hex) con sal diaria en T023 | Info / T023 |
| 2026-10-05 | DQR-T022 | H6 INFO: `record_scan` registra escaneos de enlaces pausados/archivados u orgs suspendidas → definir si cuentan | Info / product · T023 |
| 2026-10-05 | DQR-T022 | H7 INFO: service_role puede UPDATE/DELETE/TRUNCATE; UNIQUE con ACCESS EXCLUSIVE; RLS por fila → rollups; cascade largo | Info |
