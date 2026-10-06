# AGENTS.md — Dynamic QR

Reglas para **todos** los agentes (Claude Code, Codex, Copilot, OpenCode…) que trabajen en este repo.

> Dynamic QR es un proyecto independiente: plataforma SaaS multi-tenant de QR dinámicos + NFC.
> Monky (plataforma) → organizaciones (clientes) → enlaces dinámicos. No importar entidades, código ni reglas de otros proyectos.

## Fuentes de verdad
| Qué | Dónde |
|---|---|
| Especificación | `docs/` (este repo) — espejo de Notion "Dynamic QR — Project Hub" |
| Módulos | `docs/modules/DQR-xx-*.md` |
| Decisiones | `docs/adr/` |
| Tablero | Notion BD "DQR · Tareas" (principal) · `BOARD.md` (espejo) |

## Agentes
| ID | Agente | Responsabilidad | Escribe en | Modelo |
|---|---|---|---|---|
| AGENT-00 | orchestrator | Planifica, asigna, revisa, fusiona, mantiene tablero | `BOARD.md`, Notion | Opus |
| AGENT-01 | product | Requisitos y criterios de aceptación | `docs/` | Sonnet |
| AGENT-02 | db-architect | Migraciones, RLS, funciones, rollups | `supabase/` | Opus |
| AGENT-03 | backend-api | FastAPI: API, redirector, servicios | `apps/api/` | Sonnet |
| AGENT-04 | qr-nfc | Generación/diseño QR, plantillas, Canva, NFC | `apps/api/app/services/qr_*`, `routers/qr.py`, `routers/nfc.py` | Sonnet |
| AGENT-05 | analytics | Eventos, enriquecimiento, métricas | `apps/api/app/services/scan_*`, `routers/stats.py` | Sonnet |
| AGENT-06 | frontend | Dashboard Next.js | `apps/web/` | Sonnet |
| AGENT-07 | security-reviewer | Revisión de RLS, abuso, auditoría | `docs/06-seguridad.md` | Opus |
| AGENT-08 | qa | pytest, tests SQL, Playwright | `**/tests/`, `apps/web/e2e/` | Sonnet |
| AGENT-09 | devops | Monorepo, CI, Vercel, Supabase | `.github/`, `vercel.json`, `Makefile` | Sonnet |
| AGENT-10 | scribe | Docs y tablero | `docs/`, `BOARD.md` | Haiku |

Definiciones de subagente para Claude Code: `.claude/agents/*.md`.

## Estados
`BACKLOG → READY → IN_PROGRESS → IN_REVIEW → (CHANGES_REQUESTED → IN_PROGRESS) → TESTING → DONE`
`BLOCKED` desde cualquier estado, con el motivo en **Bloqueos**.

| Estado | Significa | Quién lo pone |
|---|---|---|
| BACKLOG | Definida, no aprobada | orchestrator |
| READY | Aprobada; dependencias en DONE | orchestrator (con OK del usuario por sprint) |
| IN_PROGRESS | Un agente trabaja en su rama | agente |
| BLOCKED | Falta decisión, dependencia o acceso | agente / orchestrator |
| IN_REVIEW | PR abierto, CI verde | agente |
| CHANGES_REQUESTED | La revisión pidió cambios | orchestrator / security-reviewer |
| TESTING | Fusionado; qa verifica | orchestrator |
| DONE | Verificado; Resultado y Revisado por llenos | qa / orchestrator |

## Tarjeta de tarea (siempre completa)
```
AGENT-03 backend-api
TASK:          DQR-T021
STATUS:        IN_PROGRESS
MODULE:        DQR-03 Redirector
DEPENDENCIES:  DQR-T018
FILES:         apps/api/app/routers/redirect.py
BRANCH:        feat/DQR-T021-redirector
PR:            —
BLOCKERS:      None
RESULT:        —
REVIEWED BY:   —
```

## Pasos por tarea
1. Tomar solo tareas **READY** con dependencias en **DONE**. Pasar a IN_PROGRESS y llenar Rama.
2. Leer este archivo y `docs/modules/DQR-xx-*.md` del módulo.
3. Rama `feat/DQR-Txxx-<corto>` desde `main`, en worktree aislado. Nunca dos agentes en la misma rama.
4. Base de datos: solo **db-architect**. Expand → deploy → contract. **security-reviewer** aprueba. Producción solo con OK del usuario.
5. Tests junto con el código: pytest (`apps/api/tests`), SQL `BEGIN…ROLLBACK` (`supabase/tests`), Playwright (`apps/web/e2e`).
6. PR con `[DQR-Txxx]` en el título; lint, tipos, tests y build en verde → IN_REVIEW con enlace al PR.
7. Orchestrator revisa → CHANGES_REQUESTED o fusiona → TESTING → qa verifica → DONE (llenar Resultado y Revisado por).

## Definición de DONE
- Cumple el **Criterio de hecho** de la tarea y los criterios de aceptación del módulo.
- Tests nuevos en CI, en verde.
- Docs actualizadas si cambió comportamiento, API o modelo de datos.
- Revisado por quien corresponde y verificado.

## Reglas de oro
- Una tarea = una rama = un PR pequeño y enfocado.
- Nada a `main` sin revisión del orchestrator. Nada en producción (migraciones, deploy, dominio, costos) sin OK del usuario.
- Spec ambigua → **BLOCKED** con la duda escrita en Notas del agente. No inventar.
- Ningún secreto en el repo (`.env` ignorado; usar `.env.example`).
- El redirector nunca devuelve 301 y nunca redirige a una URL que no esté guardada (sin open redirect).
- Toda tabla de negocio lleva `org_id` y RLS.

## Skills recomendadas por agente
| Agente | Skills |
|---|---|
| db-architect | supabase, supabase-postgres-best-practices |
| backend-api, qr-nfc, analytics | python-design-patterns, python-code-style, python-testing-patterns, supabase |
| frontend | frontend-design, impeccable, shadcn, vercel:nextjs |
| qr-nfc (diseño) | canvas-design, conector de Canva |
| qa | python-testing-patterns, playwright-best-practices, webapp-testing |
| security-reviewer | supabase, supabase-postgres-best-practices |
| devops | vercel:deploy, vercel:env-vars, supabase |
