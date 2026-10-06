# Dynamic QR

**Dynamic QR** es una plataforma SaaS multi-tenant de códigos QR y tarjetas NFC dinámicos. Permite crear, diseñar y analizar enlaces dinámicos que redirigen a destinos específicos, con soporte para múltiples organizaciones, usuarios, planes y auditoría completa.

Repositorio: `nfc-qr-redirector-dinamico` (monorepo).
- **Especificación y hub del proyecto:** [`docs/00-hub.md`](docs/00-hub.md)
- **Flujo y roles de agentes:** [`AGENTS.md`](AGENTS.md)
- **Tablero de tareas:** [`BOARD.md`](BOARD.md) (espejo en Notion "DQR · Tareas")
- **Documentación técnica:** [`docs/`](docs/)

Stack: **FastAPI** (Python) · **Next.js** (React) · **Supabase** (PostgreSQL) · **Vercel** (hosting) · **pg_cron** (jobs).

## Requisitos
- **Python 3.12** con [uv](https://docs.astral.sh/uv/)
- **Node.js 20+** con [pnpm](https://pnpm.io/)
- **Docker** (Supabase local)
- **Make**

## Arranque local

```bash
# Desarrollo completo
make dev

# O por partes
make db     # Supabase local + migraciones (http://127.0.0.1:54321)
make api    # FastAPI (http://localhost:8000)
make web    # Next.js dashboard (http://localhost:3000)

# Limpieza
make clean
```

### Variables de entorno
Copia `.env.example` → `.env` local:
```bash
cp .env.example .env
```
Rellena con valores de `supabase start` (proyecto local).

## Tests y calidad
```bash
# Tests SQL (PostgreSQL, tenancy + RLS)
make test-db

# Tests Python (pytest, api y servicios)
make test-api

# Tests E2E (Playwright, dashboard)
make test-e2e

# Linting y type checking
make lint typecheck

# Build de producción
make build
```

## Documentación
| Tema | Archivo |
|---|---|
| Especificación del producto | [`docs/01-producto.md`](docs/01-producto.md) |
| Modelo de datos | [`docs/03-modelo-datos.md`](docs/03-modelo-datos.md) |
| API REST | [`docs/04-api.md`](docs/04-api.md) |
| Seguridad y revisiones | [`docs/06-seguridad.md`](docs/06-seguridad.md) |
| Deploy e infraestructura | [`docs/07-deploy.md`](docs/07-deploy.md) |
| Runbook operativo | [`docs/runbook.md`](docs/runbook.md) |

## Desarrollo
Cambios en **ramas de features** (`feat/DQR-Txxx-corto`). PRs contra `main`; CI ejecuta tests, lint y build.

Ver [`AGENTS.md`](AGENTS.md) para:
- Definición de tareas (módulos, criterios de aceptación)
- Estados y transiciones
- Roles de agentes (orchestrator, backend-api, db-architect, qr-nfc, frontend, security-reviewer, etc.)
- Reglas de oro (no secrets, multi-tenant, RLS, auditoría)
