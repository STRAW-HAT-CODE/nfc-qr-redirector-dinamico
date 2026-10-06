# Runbook operativo

Cuándo actuar y cómo. Valores sin secretos; las claves viven en las env vars de Vercel/Supabase.

## 1. Monitoreo

### Uptime
Dos checks cada 1 min (Vercel Checks, o un monitor externo como UptimeRobot/Better Stack):

| Check | URL | Éxito |
|---|---|---|
| API | `https://<dominio-corto>/healthz` | 200 **y** cuerpo contiene `"db":"ok"` |
| Redirector | `https://<dominio-corto>/r/<slug-de-prueba>` (sin seguir redirects) | 302 al destino esperado |

- Slug de prueba: crear un enlace dedicado `monitor-check` en una organización interna con destino estable (p. ej. la web). Sus escaneos cuentan en analytics: filtrarlos o aceptar el ruido (1/min).
- `/healthz` devuelve 200 aunque la BD esté degradada; la alerta de BD sale de la cadena `"db":"degraded"` (alerta tras 3 fallos seguidos), la de caída del proceso de un status ≠ 200.
- Mientras `dqr-api` tenga Deployment Protection activa (ver `07-deploy.md`) el monitor recibirá 302 de SSO; resolver esa decisión antes de configurar monitores.

### Latencia (p95 > 300 ms)
- Fuente: Vercel → proyecto `dqr-api` → Observability (duración de funciones por ruta), o agregar `duration_ms` de los logs JSON (`path = "/r/{slug}"`) en el drain de logs.
- Alerta: p95 de `/r/{slug}` > 300 ms durante 5 min → aviso al canal de operaciones. Si se usa un drain (Datadog/Axiom/Better Stack), la consulta es `p95(duration_ms) where path="/r/{slug}"`.
- Primeros pasos: comparar con `db` de `/healthz` y los logs `resolve_link falló`; revisar región (`iad1` junto a Supabase us-east-2) y arranques en frío.

### Errores
Logs `level=ERROR` (todo 5xx se loguea sin muestreo) y Sentry si `SENTRY_DSN` está definido. Correlacionar con `request_id` (cabecera `x-request-id` de la respuesta).

## 2. Backups (Supabase)
- **Plan Pro o superior:** backups diarios automáticos (Dashboard → Database → Backups); PITR como add-on. **Plan Free:** no hay backups descargables; programar `pg_dump` semanal desde un job externo (`supabase db dump --linked -f backup.sql`) y guardarlo cifrado fuera del repo.
- **Verificación (mensual y tras cada cambio de plan):**
  1. Confirmar en el dashboard que existe un backup de las últimas 24 h.
  2. Restaurar el último en un proyecto/DB desechable (o con `supabase db reset` + volcado local) y comprobar: `select count(*) from links;` y `select max(created_at) from scan_events;` coinciden con producción dentro del margen.
  3. Anotar fecha, backup usado y resultado en el registro de operaciones.
- Un backup no probado cuenta como no existente.

## 3. Incidentes

### Se cae el redirector (`/r` falla o 5xx)
1. Mirar `/healthz`: proceso vivo y `db`.
2. `db: degraded` → estado de Supabase (status.supabase.com), logs `resolve_link falló`, pausa del proyecto o claves rotadas (la service key debe ser la legacy JWT).
3. Proceso caído tras un deploy → Vercel → Deployments → **Instant Rollback** al último bueno (acción de producción: requiere OK del usuario).
4. Los errores 503 del redirector son genéricos a propósito; el detalle está en los logs (`request_id`).
5. Verificar con `/r/<slug-de-prueba>` y cerrar el incidente anotando causa y duración.

### Abuso (spam, phishing, scraping)
1. **Rate limit** (T050): límites por IP en `/r/*` (`RATE_LIMIT_REDIRECT_PER_MIN`/`_BURST`); bajarlos en Vercel y redeploy. Con varias instancias, configurar `UPSTASH_REDIS_REST_URL/TOKEN` para que el límite sea compartido.
2. **Suspender un enlace:** poner su estado en suspendido/inactivo (`PATCH /v1/links/{id}` o `update links set status=...` con service role, según el esquema vigente) → `/r/<slug>` responde 404 amable. Queda en `audit_log`.
3. **Blocklist de destinos:** la política de URL (`services/url_policy.py`) rechaza destinos nuevos; añadir el dominio abusivo allí y suspender los enlaces existentes que apunten a él.
4. Si el abuso es de una organización: suspenderla o retirar sus miembros (auditado) y avisar a security-reviewer.
5. Conservar `request_id` y `audit_log` como evidencia; no copiar IPs a tickets (solo se guarda `ip_hash`).

### Rotar `IP_HASH_SALT`
Cuándo: sospecha de filtración o rotación periódica (anual).
1. Generar: `openssl rand -hex 32` (no pegarla en chats ni en el repo).
2. Vercel → `dqr-api` → Environment Variables → actualizar `IP_HASH_SALT` del entorno (Preview o Production).
3. Redeploy del entorno (las funciones leen la variable al arrancar).
4. Efecto esperado: los `ip_hash` anteriores y los nuevos dejan de ser correlacionables, así que los "visitantes únicos" se reinician en el corte. Es intencional y se anota en el registro de operaciones.
5. Verificar un escaneo de prueba: `scan_events.ip_hash` nuevo no nulo (requiere `TRUSTED_PROXY_HOPS=1`).

### Rotar claves de Supabase / JWT
Regenerar en Settings → API, actualizar las env vars de Vercel de ambos proyectos, redeploy y comprobar `/healthz` (`db: ok`). Usar el canal seguro del usuario; nunca por logs ni PRs.
