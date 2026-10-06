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

| | local | staging | production |
|---|---|---|---|
| Dónde vive | Docker vía Supabase CLI (`http://127.0.0.1:54321`) | Proyecto Supabase `<staging-project-ref>` + Vercel (preview) | Proyecto Supabase propio + Vercel (`main`) |
| Cómo se crea | `supabase start` | Proyecto creado por el orquestador; enlazar con `supabase link --project-ref <staging-project-ref>` | Solo con OK del usuario |
| Quién migra | db-architect, desde `supabase/migrations/` (`supabase db reset`) | db-architect, desde `supabase/migrations/` (`supabase db push`) | db-architect, desde `supabase/migrations/`, **solo con OK del usuario** y aprobación de security-reviewer |
| Secretos | `.env` local (git-ignorado) | Env vars de Vercel | Env vars de Vercel |

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

### Claves
Las claves de staging y production viven únicamente en las env vars de Vercel; nunca en el repo, issues, PRs ni logs.

## Variables (`.env.example`)
```
SUPABASE_URL=
SUPABASE_ANON_KEY=
SUPABASE_SERVICE_ROLE_KEY=      # solo servidor
SUPABASE_JWT_SECRET=
PUBLIC_REDIRECT_BASE_URL=       # https://<dominio-corto>
IP_HASH_SALT=
NEXT_PUBLIC_SUPABASE_URL=
NEXT_PUBLIC_SUPABASE_ANON_KEY=
NEXT_PUBLIC_API_URL=
```

## Observabilidad
Logs estructurados, errores, uptime de `/healthz` y `/r`, alerta si p95 > 300 ms, backups diarios verificados.
