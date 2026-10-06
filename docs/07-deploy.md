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
