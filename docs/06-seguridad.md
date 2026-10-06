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
| 2026-10-05 | DQR-T021 | H1 MEDIA: destino/fallback no ASCII → Location latin-1 corrupto o 503 permanente → `quote(url, safe="!#$%&'()*+,/:;=?@[]~")` + exigir http(s) | Resuelto |
| 2026-10-05 | DQR-T021 | H2 MEDIA: `redirect_slashes` → `/r/{slug}/` da 307 a `http://{Host}/…` sin no-store (cabecera en Location) → `FastAPI(redirect_slashes=False)` + ruta con barra final + prueba con Host hostil | Resuelto |
| 2026-10-05 | DQR-T021 | H3 BAJA: cuerpo dict o destino None → 500 sin no-store; `""` → Location vacío → fila procesada dentro del try, `except Exception` → 503, validar esquema | Resuelto |
| 2026-10-05 | DQR-T021 | H4 INFO: `t` libre (ASCII ≤ 64) frente a `tag_id` uuid → T023 valida uuid o no lo pasa hasta T034 | Info / T023 |
| 2026-10-05 | DQR-T021 | H5 INFO: tope total del RPC (`asyncio.timeout(1.5)` → 503, hecho); falta fail-fast si no hay key (T055); rate limit en T050; archived va a fallback como pausado (decisión de producto); filtrar apikey en un APM | Parcial / T055 · T050 |
| 2026-10-05 | DQR-T021 | R1 BAJA: `HTTPS://` guardado (la BD lo acepta con `~*`) → 503 permanente → esquema comparado sin distinguir mayúsculas (`urlsplit(url).scheme.lower()`) | Resuelto |
| 2026-10-05 | DQR-T021 | R2 INFO (proceso): las filas de docs/06 las añade security-reviewer o el orquestador, no el agente de la tarea | Info / proceso |
| 2026-10-05 | DQR-T034 | Cierra T022-H1: FK (tag_id, link_id) → nfc_tags (id, link_id) on delete set null; `record_scan` guarda NULL si la etiqueta no es del enlace; limpieza probada con 5000 tag_id basura (0 eventos perdidos) | Resuelto |
| 2026-10-05 | DQR-T034 | H1 BAJA: `record_scan` se reemplaza después de añadir la FK y sin `LOCK` previo → ventana en que la migración aborta o se pierde un escaneo → reemplazar `record_scan` primero y `lock table scan_events in share row exclusive mode` antes de limpiar; a escala, VALIDATE e índice concurrente aparte | Resuelto (migración reordenada en el PR #15) |
| 2026-10-05 | DQR-T034 | H2 INFO: label/location admiten caracteres de formato Unicode → filtro opcional como `scan_clip` | Resuelto (CHECK con los rangos de `scan_clip`) |
| 2026-10-05 | DQR-T034 | H3 INFO: oráculo de existencia de link por error de FK (uuid v4, aceptable); aplicar #16 antes que #15; desplegar T023 después de T034 | Info |
| 2026-10-05 | DQR-T023 | Cierra T022-H4/H5 y T021-H4: referer solo como origen, ip_hash = HMAC-SHA256 en hex de 64 con la fecha UTC, XFF solo con `TRUSTED_PROXY_HOPS`, tag solo uuid y nfc, org suspendida sin registrar, nunca rompe el 302 ni loguea la IP | Resuelto |
| 2026-10-05 | DQR-T023 | H1 BAJA: la IP no se valida ni normaliza antes del HMAC (variantes IPv6, IPv4 mapeada, puerto, basura de XFF) → `ipaddress.ip_address(...).compressed`, basura → NULL | Resuelto |
| 2026-10-05 | DQR-T023 | H2 BAJA: la "sal diaria" es un secreto fijo más la fecha; con `IP_HASH_SALT` se revierte IPv4 de cualquier día → sal efímera diaria en `private.daily_salts` borrada a las 48 h | Backlog / DQR-08 · T040 |
| 2026-10-05 | DQR-T023 | H3 BAJA: `TRUSTED_PROXY_HOPS` por defecto 0 y fuera de `.env.example`/docs/07 (en Vercel, únicos = 1 o null); `x-vercel-ip-country` se lee aunque no haya proxy confiable | Resuelto (documentado; país solo con hops ≥ 1) |
| 2026-10-05 | DQR-T023 | H4 INFO: medir en staging que la BackgroundTask no retrase el 302 en Vercel Python Functions (p95 < 150 ms) | Info / T024 |
| 2026-10-05 | DQR-T023 | H5 INFO: se registran los escaneos de pausados/archivados/vencidos (producto confirma); los logs de plataforma de Vercel guardan la IP → configurar retención | Info / product · devops |
| 2026-10-05 | DQR-T031 | H1 BAJA: el nombre del objeto en `logos` admite cualquier extensión (`.html`, `.svg`); el MIME lo limita el bucket → exigir `\.(png\|jpe?g\|webp)$` en `logo_path_org_id` o en las políticas | Recomendado |
| 2026-10-05 | DQR-T031 | H2 BAJA: sin cuota de logos por org (abuso de coste con registro libre) → límite en la política o en la API contra `organizations.limits` | Backlog / T032 · T050 · DQR-09 |
| 2026-10-05 | DQR-T031 | H3 INFO: T032 comprueba magic bytes, limita `MAX_IMAGE_PIXELS`, descarga solo por `logo_path` de BD, URL firmada con TTL corto y lista blanca de `style` | Info / T032 |
| 2026-10-05 | DQR-T031 | H4 INFO: logos huérfanos al borrar; org suspendida sigue editando; fusionar #16 antes que #15 (orden de timestamps) | Info / T052 · DQR-09 |
| 2026-10-06 | DQR-T032 | Verificado: logo re-encodeado a PNG sin metadatos (políglotas limpios), formato por contenido, > 4 Mpx rechazado sin descomprimir, JWT del usuario (sin service role), ruta generada en el servidor, logo solo desde `logo_path` propio (sin SSRF ni traversal), SVG con `frame_text` escapado, descargas `attachment` + `nosniff` + `no-store` | Verificado |
| 2026-10-06 | DQR-T032 | H1 BAJA: el multipart se parsea antes de la auth y sin límite (200 MB anónimos en 630 ms; Vercel corta en 4,5 MB) → rechazar por `Content-Length` en una dependencia previa o con un middleware de tamaño | Recomendado |
| 2026-10-06 | DQR-T032 | H2 BAJA: con #30, `plan_limit_reached` de logos → 502 → usar `plan_limit_error` en `_map_db_error` de qr_designs | Abierto / integración #29–#30 |
| 2026-10-06 | DQR-T032 | H3 INFO: render ≤ 0,4 s y ~50 MB por descarga 4096 (rate limit T050 / caché); huérfanos por carrera; `logo_path` no PNG → 500 | Info / T050 · T031-H4 |
| 2026-10-06 | DQR-T041 | H1 MEDIA: `org_stats`/`link_stats` (INVOKER) sin guarda; un usuario ajeno obliga a leer los datos de otra org (4 s de CPU por llamada, 0 filas) → `return` temprano si no es miembro o platform admin (35 ms) | Abierto (CHANGES_REQUESTED) |
| 2026-10-06 | DQR-T041 | H2 MEDIA: la RLS `is_org_member(org_id)` por fila deja 90 días en 1,74 s (criterio < 200 ms) → política `org_id in (select private.my_org_ids())` (265 ms); extender al resto de tablas | Recomendado / db-architect |
| 2026-10-06 | DQR-T041 | H3 BAJA: cerrar el día justo a medianoche pierde escaneos que hacen commit tarde → cerrar con margen (`now() - 10 min`) | Recomendado |
| 2026-10-06 | DQR-T041 | H4 INFO: `is_bot` marcado después del cierre no recalcula → T040 marca antes del insert o hace refresh de los días afectados | Info / T040 |
| 2026-10-06 | DQR-T041 | H5 INFO: alertar si la marca de agua se atrasa; la API usa el JWT del usuario para las métricas; backfill por tramos a escala | Info / T042 · devops |
| 2026-10-06 | DQR-T051 | Verificado: las 7 `admin_*` exigen platform admin antes de leer o escribir (42501); SECURITY DEFINER + `search_path=''`; sin anon ni service_role; sin escalada (`platform_admins`, org con UUID nulo, `private.*`); limits validados por CHECK; dominios normalizados y validados; búsqueda con comodines escapados y paginación acotada | Verificado |
| 2026-10-06 | DQR-T051 | H1 ALTA: la "suspensión" de enlace (paused/archived) la revierte un editor y, mientras dura, redirige al `fallback_url` de la org → `suspended_at` no editable por la org, guard que bloquea cambios y redirector sin fallback para suspendidos | Abierto (CHANGES_REQUESTED) |
| 2026-10-06 | DQR-T051 | H2 MEDIA: `my_effective_role(nil)` es NULL para el platform admin; no hay RPC para saber si lo soy → `public.am_i_platform_admin()` | Abierto (CHANGES_REQUESTED) |
| 2026-10-06 | DQR-T051 | H3 BAJA: la blocklist acepta `com`/`localhost` (radio enorme por error) → exigir al menos un punto | Recomendado |
| 2026-10-06 | DQR-T051 | H4 INFO: blocklist sin efecto en enlaces existentes (T018-H8); `admin_list_orgs` cuenta eventos en vivo; los tests con dblink dejan filas permanentes en audit_log | Info |
| 2026-10-06 | DQR-T052 | H1 MEDIA: RLS `has_org_role` por fila → un extraño fuerza un recorrido completo de `audit_log` vía PostgREST (2,1 s con 320 k filas, crece sin purga) → política `org_id in (select private.my_admin_org_ids())` (97 ms) | Abierto (CHANGES_REQUESTED) |
| 2026-10-06 | DQR-T052 | H2 BAJA: la plantilla comentada de qr_designs usa `id` (no existe) y rompería sus escrituras; la de nfc_tags usa `status`; nfc_tags ya está en main sin auditar → corregir y crear el trigger de nfc_tags | Abierto |
| 2026-10-06 | DQR-T052 | Append-only verificado: service_role sin UPDATE/DELETE/TRUNCATE/INSERT; postgres bloqueado por trigger; actor = `auth.uid()` no falsificable; lectura admin+ y platform admin; `link.deleted` conserva el último destino (cierra T018-H6) | Verificado |
| 2026-10-06 | DQR-T052 | H3 INFO: escrituras de la API con service role quedan con actor NULL → usar el JWT del usuario | Info / API |
| 2026-10-06 | DQR-T052 | H4 INFO: sin auditoría de borrado de org ni de limits/slug; `diff` con URLs completas sin retención definida | Info / DQR-09 · product |
| 2026-10-06 | DQR-T052 | H5 INFO: #16 (qr_designs `025924`) necesita un timestamp posterior a `031500` antes de fusionar | Info / orquestador |
| 2026-10-06 | DQR-T053 | Verificado: límites en BD con lock `FOR NO KEY UPDATE` de la org (carrera real probada con dblink), exenciones por `current_user`/platform admin no falsificables, sin lock ni oráculo para quien no tiene rol, plan/limits solo platform admin, FK y CHECK de formato, `create_organization` ≤ 5 (cierra T013-H5), 409 en la API | Verificado |
| 2026-10-06 | DQR-T053 | H1 BAJA: `max_logos` cuenta `qr_designs`, no objetos; un editor sigue subiendo objetos ilimitados al bucket `logos` (T031-H2 abierto) → límite en `logos_insert` o limpieza de huérfanos | Abierto / db-architect |
| 2026-10-06 | DQR-T053 | H2 INFO: toda RPC SECURITY DEFINER futura que cree recursos limitados debe llamar a `enforce_plan_limit`; purga por `scans_retention_days` pendiente | Info |
| 2026-10-06 | DQR-T054 | Verificado: `/v1/admin` y `/v1/me` solo con el JWT del usuario (sin service role); la BD decide (42501 → 403); `require_role` vía `my_effective_role` falla cerrado (error → 502, rol desconocido → sin acceso); bodies con `extra=forbid` y rangos | Verificado |
| 2026-10-06 | DQR-T054 | H1 MEDIA: `/v1/me` usa `my_effective_role(nil)`, que es NULL para el platform admin → siempre false; los tests mockean el contrato erróneo → usar `am_i_platform_admin()` (sec-T051 H2) | Abierto (CHANGES_REQUESTED) |
| 2026-10-06 | DQR-T054 | H2 BAJA: FK de plan (23503) → 404 en vez de 422 | Recomendado |
| 2026-10-06 | DQR-T054 | H3 INFO: DELETE con cuerpo; acciones de owner del platform admin auditadas; "suspender" enlace depende de sec-T051 H1 | Info |
| 2026-10-06 | DQR-T057 | Auditoría pre-lanzamiento sobre `main` f1e2980 + staging: advisors **0 errores** (11 WARN SECURITY DEFINER intencionadas, INFO deny-all/índices); RLS en todas las tablas de public; anon sin privilegios; todas las SECURITY DEFINER con `search_path=''`; 1.027 tests SQL + 648 pytest en verde; redirector sin open redirect, sin 301, no-store, suspendidos sin fallback; historial git sin secretos; pip-audit y `pnpm audit --prod` limpios | Verificado |
| 2026-10-06 | DQR-T057 | B1 MEDIA: la web no envía CSP, X-Frame-Options, Referrer-Policy, Permissions-Policy ni HSTS (clickjacking del dashboard) → `headers()` en `next.config.ts` (propuesta en sec-T057) | Abierto · bloquea el lanzamiento |
| 2026-10-06 | DQR-T057 | B2 ALTA (config): producción necesita `TRUSTED_PROXY_HOPS=1` (si no, el rate limit de `/r` bloquea a todos), Upstash (si no, el límite es por instancia), `IP_HASH_SALT` propia y `PUBLIC_REDIRECT_BASE_URL` | Abierto · bloquea el lanzamiento |
| 2026-10-06 | DQR-T057 | B3 ALTA (config): allowlist de Redirect URLs de Supabase Auth sin comodines (riesgo de robo del `code` de enlaces mágicos) + protección de contraseñas filtradas; recomendado `emailRedirectTo` desde `SITE_URL` | Abierto · bloquea el lanzamiento |
| 2026-10-06 | DQR-T057 | B4 MEDIA: advisors con `--fail-on error` sobre la BD de producción tras migrar + alta de al menos un platform admin | Abierto · bloquea el lanzamiento |
| 2026-10-06 | DQR-T057 | B5 MEDIA: `dqr-api` (dominio corto) sin Deployment Protection; smoke de `/r` 404 amable | Abierto · bloquea el lanzamiento |
| 2026-10-06 | DQR-T057 | Backlog post-lanzamiento: blocklist no retroactiva (T018-H8), cuota de objetos de Storage (T031-H2), sal efímera de ip_hash (T023-H2), límite de `/r` para NAT compartido, CSP con nonce, multipart antes de la auth (T032-H1), 409 `link_suspended`, validar el CHECK de la blocklist | Backlog |
| 2026-10-06 | DQR-T015 | Revisión S1 (T013, T018, T021, T022) cerrada: MEDIA/ALTA resueltos; T013-H5, T018-H4, T022-H1/H4/H5 y T021-H5 cerrados por T053, T051, T034, T023 y T050; abiertos T018-H8, T013-H4 y T023-H2 en el backlog de T057 | Resuelto |
