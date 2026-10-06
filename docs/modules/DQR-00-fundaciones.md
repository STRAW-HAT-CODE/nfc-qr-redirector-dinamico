# DQR-00 · Fundaciones

| Campo | Valor |
|---|---|
| Depende de | — |
| Agente líder | devops |
| Sprint | S1 |
| Tareas | DQR-T010, DQR-T011 |

## Alcance
Monorepo `apps/api` (FastAPI + uv), `apps/web` (Next.js), `supabase/`; Makefile; CI; convenciones.

## Criterios de aceptación
- `make dev` levanta API (`/healthz` 200), web y Supabase local.
- CI ejecuta ruff, mypy, pytest, next lint/build y supabase db lint; falla si algo falla.
- `.env.example` completo; `.env` ignorado.

## Archivos esperados
- `apps/api/pyproject.toml`
- `apps/api/app/main.py`
- `apps/web/`
- `supabase/config.toml`
- `Makefile`
- `.github/workflows/ci.yml`

## Referencias
- docs/03-modelo-datos.md · docs/04-api.md · AGENTS.md
