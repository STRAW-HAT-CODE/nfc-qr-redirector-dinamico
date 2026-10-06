# 7 · Deploy e infraestructura

| Pieza | Dónde | Notas |
|---|---|---|
| Dashboard | Vercel (Next.js) | Preview por PR, producción en `main` |
| API + redirector | Vercel Python Functions (FastAPI) | Región cercana a Supabase |
| Base de datos, Auth, Storage | Supabase | Proyectos separados: staging y producción |
| Dominio corto | Propio, apuntando al redirector | Compra solo con OK del usuario |
| Jobs | pg_cron (rollups) | |

## Entornos
`local` (Supabase CLI) → `staging` → `production`. Migraciones solo desde `supabase/migrations/`; nunca cambios manuales en producción.

**Decisión MVP (2026-10-06):** Desarrollo en local con Supabase CLI; `staging` = proyecto `huufgmpzusmzmujldxol` (nfc-redirect-api); `production` = **mismo proyecto** (`nfc-redirect-api`, como producción real del MVP); _staging como entorno separado_ es un futuro (limitado a 2 proyectos free en Supabase).

| | local | staging (MVP) | production (futuro) |
|---|---|---|---|
| Dónde vive | Docker vía Supabase CLI (`http://127.0.0.1:54321`) | Proyecto Supabase `huufgmpzusmzmujldxol` (`nfc-redirect-api`, us-east-2, org Alexdev, `https://huufgmpzusmzmujldxol.supabase.co`) + Vercel Preview | Proyecto Supabase nuevo + Vercel Production · _O_ ampliar Supabase plan a 2+ proyectos |
| Cómo se crea | `supabase start` en worktree | `supabase link --project-ref huufgmpzusmzmujldxol` en worktree T055b | A decidir: nuevo proyecto o upgrade de plan Supabase |
| Quién migra | db-architect, desde `supabase/migrations/` (`supabase db reset`) | db-architect, desde `supabase/migrations/` (`supabase db push --linked`), sin `--skip-seed` | db-architect, con OK del usuario y aprobación de security-reviewer |
| Secretos | `.env` local (git-ignorado) | Env vars de Vercel (Preview) | Env vars de Vercel (Production) |

### Rellenar `.env` por entorno
1. `cp .env.example .env`.
2. **Local:** ejecuta `supabase start` y copia API URL, `anon key`, `service_role key` y `JWT secret` a las variables correspondientes. Las `NEXT_PUBLIC_*` repiten los valores públicos.
3. **Staging/production:** toma los valores en el dashboard del proyecto (Settings → API) y cárgalos como env vars en Vercel (Project → Settings → Environment Variables), por entorno (Preview = staging, Production = production). No se escriben en archivos del repo.
4. `SUPABASE_SERVICE_ROLE_KEY`, `SUPABASE_JWT_SECRET` e `IP_HASH_SALT` son **solo servidor**: nunca con prefijo `NEXT_PUBLIC_` ni en código de cliente.

### Generar `IP_HASH_SALT`
```
openssl rand -hex 32
```
Usa un valor distinto por entorno. Rotarlo invalida la correlación de hashes previos.

### `TRUSTED_PROXY_HOPS`
Número de proxies confiables delante de la API. Con `0` (por defecto, local) se usa la IP de la conexión y se ignoran `x-forwarded-for` y `x-vercel-ip-country`. En Vercel, **1** en Preview y Production: la plataforma pone `x-forwarded-for` (se toma la entrada N desde la derecha) y `x-vercel-ip-country`. Con `0` en Vercel, los únicos salen en 1 o `ip_hash` null.

### Claves
Las claves de staging y production viven únicamente en las env vars de Vercel; nunca en el repo, issues, PRs ni logs.

## Vercel (DQR-T055, fase preview sobre staging)

Cuenta/equipo: `davides-projects-6878c5d7`. Dos proyectos, ambos con región de funciones `iad1` (cerca de us-east-2) fijada en el `vercel.json` de cada app.

| Proyecto | Root Directory | Framework | Entrada |
|---|---|---|---|
| `dqr-web` | `apps/web` | Next.js | autodetectada |
| `dqr-api` | `apps/api` | FastAPI (Python Functions) | `app/main.py` (variable `app`), dependencias desde `pyproject.toml`/`uv.lock` |

Vincular y desplegar un preview (nunca `--prod` sin OK del usuario):
```
cd apps/api && pnpm dlx vercel link --yes --project dqr-api && pnpm dlx vercel deploy
cd apps/web && pnpm dlx vercel link --yes --project dqr-web && pnpm dlx vercel deploy
```
`.vercel/` está git-ignorado.

### Variables por entorno (sin valores)
| Variable | Proyecto | Preview (staging) | Production |
|---|---|---|---|
| `SUPABASE_URL` | api | cargada (preview) | pendiente |
| `SUPABASE_ANON_KEY` | api | cargada (preview) | pendiente |
| `SUPABASE_SERVICE_ROLE_KEY` | api | cargada (preview, sensible) | pendiente |
| `SUPABASE_JWT_SECRET` | api | vacía: la API verifica con JWKS | pendiente |
| `IP_HASH_SALT` | api | cargada (preview; generada con `openssl rand -hex 32`) | pendiente, distinta |
| `TRUSTED_PROXY_HOPS` | api | `1`, cargada (preview) | pendiente |
| `PUBLIC_REDIRECT_BASE_URL` | api | cargada (preview) | dominio corto |
| `NEXT_PUBLIC_SUPABASE_URL` | web | cargada (preview) | pendiente |
| `NEXT_PUBLIC_SUPABASE_ANON_KEY` | web | cargada (preview; tipo config; la anon key es pública, sujeta a RLS) | pendiente |
| `NEXT_PUBLIC_API_URL` | web | cargada (preview) | pendiente |

Los secretos se cargan por pipe (`printf %s "$V" | vercel env add NAME preview`), sin escribirlos en archivos ni logs. `SUPABASE_SERVICE_ROLE_KEY` se usa como `apikey` y `Bearer`, por lo que debe ser la clave legacy `service_role` (JWT).

### CORS
No hace falta: `apps/web/lib/api.ts` llama a la API solo desde el servidor (Server Components/Actions), con el token de la cookie. Si algún día se llama desde el navegador, añadir `CORSMiddleware` con lista blanca del dominio de la web.

### Deployment Protection
Los previews de Vercel quedan tras SSO (responden 302). El redirector `/r/*` debe ser público, así que `dqr-api` necesita desactivar la protección del proyecto (solo ese proyecto, no la cuenta) o usar un bypass. **Paso pendiente: decisión del usuario (no tocar hasta entonces; no se crearon bypass ni se cambió la configuración).** Mientras tanto, verificar con `pnpm dlx vercel curl <ruta> --deployment <url>`.

### Estado del preview (2026-10-06)
- API: `https://dqr-83t9hq146-davides-projects-6878c5d7.vercel.app` (alias `https://dqr-api.vercel.app`): `/healthz` → 200.
- Web: `https://dqr-48pgwp9bk-davides-projects-6878c5d7.vercel.app`: `/login` → 200.
- `/r/AAAAAAA` → 503 genérico: la función `resolve_link` no existe aún en staging (PGRST202). Se espera 404 amable cuando el orquestador aplique las migraciones. La service key sí autentica contra PostgREST.

### Promover a producción (pendiente de OK del usuario)
1. Proyecto Supabase de producción creado y migrado (security-reviewer aprueba).
2. Cargar las variables en el entorno `production` de cada proyecto, con valores propios y `IP_HASH_SALT` distinta.
3. Dominio corto comprado y asignado a `dqr-api`; `PUBLIC_REDIRECT_BASE_URL` apunta a él.
4. `vercel deploy --prod` (o merge a `main` si se conecta Git) en `dqr-api` y luego `dqr-web`.
5. Verificar `/healthz`, `/r/AAAAAAA` (404 amable) y `/login`.

## Variables (`.env.example`)
```
SUPABASE_URL=
SUPABASE_ANON_KEY=
SUPABASE_SERVICE_ROLE_KEY=      # solo servidor
SUPABASE_JWT_SECRET=
PUBLIC_REDIRECT_BASE_URL=       # https://<dominio-corto>
IP_HASH_SALT=
TRUSTED_PROXY_HOPS=             # 0 local · 1 en Vercel (Preview y Production)
NEXT_PUBLIC_SUPABASE_URL=
NEXT_PUBLIC_SUPABASE_ANON_KEY=
NEXT_PUBLIC_API_URL=
```

## Observabilidad (DQR-T056)
Procedimientos operativos en [`docs/runbook.md`](runbook.md).

- **Logs:** una línea JSON por evento a stdout (`ts, level, logger, message, request_id`) y, por petición, `method, path` (plantilla de ruta, p. ej. `/r/{slug}`), `status`, `duration_ms`. Nunca tokens, `apikey`, cabeceras, IP cruda ni sal; los mensajes pasan por un filtro de JWT/Bearer/apikey y de las excepciones solo se registra el tipo. `x-request-id` entrante (`[A-Za-z0-9._-]{1,64}`) se respeta; si no, se genera, y siempre se devuelve en la respuesta.
- **Variables opcionales (API):** `LOG_LEVEL` (INFO), `LOG_REDIRECT_SAMPLE_RATE` (0..1, 1.0; muestrea los `/r/*` con status < 500; los 5xx siempre se loguean), `SENTRY_DSN`, `SENTRY_ENVIRONMENT`. `VERCEL_GIT_COMMIT_SHA` lo inyecta Vercel.
- **`/healthz`:** `{status, version, db}`. Responde **200 siempre que el proceso viva**; `db` es `ok` o `degraded` (ping `resolve_link` de un slug inexistente, timeout 1 s, resultado cacheado 10 s por instancia). Criterio: una BD caída no debe devolver 5xx para no marcar caído un dominio sano; el monitor de uptime alerta de `db: degraded` buscando esa cadena en el cuerpo. Excluido del rate limit.
- **Sentry (opcional):** dependencia como extra, `uv sync --extra sentry`; en Vercel añade `sentry-sdk` al despliegue si se quiere. Con `SENTRY_DSN` se inicializa con `send_default_pii=False` y `before_send` que elimina `authorization`, `apikey`, `cookie`, cookies e IP. Sin DSN o sin el paquete no hace nada.
- **Uptime, latencia y backups:** ver runbook.
