# 2 · Arquitectura

```
Visitante ──► GET /r/{slug} ──► FastAPI (redirector) ──► 302 destino
                                  │ BackgroundTask
                                  ▼
                         Supabase Postgres (scan_events)

Usuario ──► Next.js (apps/web) ──► FastAPI /v1 (JWT Supabase) ──► Postgres (RLS)
                 │                                         └──► Storage (logos)
                 └── Supabase Auth
```

## Estructura del repo
```
apps/api/            FastAPI · Python 3.12 · uv · pydantic v2 · segno · Pillow
  app/main.py
  app/routers/       redirect.py, links.py, orgs.py, qr.py, nfc.py, stats.py, admin.py
  app/services/      slug.py, url_policy.py, qr_render.py, scan_logger.py, scan_enrich.py
  tests/
apps/web/            Next.js (App Router) · shadcn/ui · @supabase/ssr
  app/(auth) app/(app) app/(platform)
  e2e/
supabase/            config.toml · migrations/ · seed.sql · tests/
docs/                especificación
```

## Reglas
- La API consulta Postgres **con el JWT del usuario** para que RLS sea la barrera real.
- Solo el redirector y los jobs internos usan la service role key.
- El redirector responde `302` + `Cache-Control: no-store` (ADR-0003).
- El canal va por parámetro sobre el mismo slug (ADR-0004).
- El registro del escaneo es un `BackgroundTask`; cualquier error se loguea y se ignora.
- Configuración solo por variables de entorno (`.env.example`).
