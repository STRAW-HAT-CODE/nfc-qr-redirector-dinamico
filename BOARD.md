# BOARD — Dynamic QR

Espejo del tablero de Notion "DQR · Tareas" (fuente principal). Lo actualiza el orchestrator o el scribe.
Estados: BACKLOG · READY · IN_PROGRESS · BLOCKED · IN_REVIEW · CHANGES_REQUESTED · TESTING · DONE

## Control de agentes
```
AGENT-00 orchestrator      Sprint 1 — coordinación                 activo (S0 DONE, S1 aprobado 2026-10-05)
AGENT-01 product           Especificación MVP                      DONE (docs/01-producto.md)
AGENT-02 db-architect      Arquitectura de BD multi-tenant         BACKLOG (T013 espera T010, T012)
AGENT-03 backend-api       API + redirector                        BACKLOG (depende de T013/T018)
AGENT-04 qr-nfc            Generación QR / NFC                     BACKLOG (depende de T020)
AGENT-05 analytics         Modelo de eventos                       BACKLOG (depende de T023 — redirector)
AGENT-06 frontend          Dashboard                               BACKLOG (depende de T017)
AGENT-07 security-reviewer Revisión S1                             BACKLOG
AGENT-08 qa                Estrategia de pruebas                   BACKLOG (definida en AGENTS.md)
AGENT-09 devops            Scaffold + Supabase                     IN_PROGRESS (T010, T012)
AGENT-10 scribe            Docs y tablero                          activo
```

## Sprint 0 — Organización (sin código)
| ID | Tarea | Agente | Estado | Dependencias | Archivos | Revisado por |
|---|---|---|---|---|---|---|
| DQR-T001 | Project Hub en Notion | orchestrator | DONE | — | Notion | usuario |
| DQR-T002 | Especificación docs/ | orchestrator | DONE | T001 | docs/ | usuario |
| DQR-T003 | Agentes AGENTS.md / .claude/agents | orchestrator | DONE | T001 | AGENTS.md, .claude/agents/ | usuario |
| DQR-T004 | ADRs iniciales | orchestrator | DONE | — | docs/adr/ | usuario |
| DQR-T005 | OK del usuario para S1 | orchestrator | DONE | T001–T004 | — | usuario (2026-10-05) |

## Sprint 1 — Fundaciones, tenancy, enlaces, redirector
| ID | Tarea | Agente | Estado | Dependencias |
|---|---|---|---|---|
| DQR-T010 | Scaffold monorepo | devops | DONE (qa PASS) | T005 |
| DQR-T011 | CI | devops | DONE (qa PASS) | T010 |
| DQR-T012 | Supabase dev/staging + .env.example | devops | DONE (PR #1 · qa PASS) | T005 |
| DQR-T013 | Migración tenancy + helpers RLS | db-architect | DONE (qa PASS · seguridad APPROVED) | T010, T012 |
| DQR-T014 | Tests RLS tenancy | qa | BACKLOG | T013 |
| DQR-T015 | Revisión seguridad S1 | security-reviewer | BACKLOG | T013, T018, T021, T022 |
| DQR-T016 | Auth FastAPI (JWT) | backend-api | IN_REVIEW (PR #6 · rebasado, CI verde) | T010, T013 |
| DQR-T017 | API orgs y miembros | backend-api | BACKLOG | T016 |
| DQR-T018 | Migración dynamic_links + historial | db-architect | IN_REVIEW (PR #7 · rebasado, CI verde, seguridad APPROVED) | T013 |
| DQR-T019 | Slug + política de URLs | backend-api | DONE (qa PASS) | T010 |
| DQR-T020 | API CRUD enlaces | backend-api | BACKLOG | T016, T018, T019 |
| DQR-T021 | Redirector /r/{slug} | backend-api | BACKLOG | T018 |
| DQR-T022 | Migración scan_events | db-architect | BACKLOG | T018 |
| DQR-T023 | Registro asíncrono del escaneo | backend-api | BACKLOG | T021, T022 |
| DQR-T024 | Tests S1 | qa | BACKLOG | T020, T023 |

## Sprint 2 — QR y NFC
| ID | Tarea | Agente | Estado | Dependencias |
|---|---|---|---|---|
| DQR-T030 | Servicio generación QR | qr-nfc | BACKLOG | T020 |
| DQR-T031 | Migración qr_designs + bucket | db-architect | BACKLOG | T018 |
| DQR-T032 | API diseño y descargas | qr-nfc | BACKLOG | T030, T031 |
| DQR-T033 | Plantillas + Canva | qr-nfc | BACKLOG | T032 |
| DQR-T034 | Migración nfc_tags | db-architect | BACKLOG | T018 |
| DQR-T035 | API NFC + guía | qr-nfc | BACKLOG | T034, T021 |
| DQR-T036 | Tests de QR | qa | BACKLOG | T032 |

## Sprint 3 — Analytics y dashboard
| ID | Tarea | Agente | Estado | Dependencias |
|---|---|---|---|---|
| DQR-T040 | Enriquecimiento + bots | analytics | BACKLOG | T023 |
| DQR-T041 | Rollups pg_cron | db-architect | BACKLOG | T022 |
| DQR-T042 | Endpoints de métricas | analytics | BACKLOG | T040, T041 |
| DQR-T043 | Next.js base + auth | frontend | BACKLOG | T010, T017 |
| DQR-T044 | Pantallas de enlaces | frontend | BACKLOG | T043, T020 |
| DQR-T045 | Diseñador de QR | frontend | BACKLOG | T044, T032 |
| DQR-T046 | Pantalla NFC | frontend | BACKLOG | T044, T035 |
| DQR-T047 | Analytics UI | frontend | BACKLOG | T042, T044 |
| DQR-T048 | Miembros UI | frontend | BACKLOG | T043 |
| DQR-T049 | E2E Playwright | qa | BACKLOG | T045, T047 |

## Sprint 4 — Seguridad, plataforma, producción
| ID | Tarea | Agente | Estado | Dependencias |
|---|---|---|---|---|
| DQR-T050 | Rate limiting | backend-api | BACKLOG | T023 |
| DQR-T051 | Política de URLs / abuso | security-reviewer | BACKLOG | T020 |
| DQR-T052 | audit_log | db-architect | BACKLOG | T018 |
| DQR-T053 | Planes y límites | db-architect | BACKLOG | T013 |
| DQR-T054 | Consola Monky | frontend | BACKLOG | T043, T053 |
| DQR-T055 | Deploy Vercel + dominio | devops | BACKLOG | T011 |
| DQR-T056 | Observabilidad | devops | BACKLOG | T055 |
| DQR-T057 | Auditoría pre-lanzamiento | security-reviewer | BACKLOG | T050–T052, T054 |
| DQR-T058 | Regresión + smoke prod | qa | BACKLOG | T055, T057 |

## Backlog abierto por revisiones
| Origen | Pendiente | Decide |
|---|---|---|
| T013 · sec H4 | Flujo para borrar la cuenta del último owner (transferir la propiedad o borrar la org) | product |
| T013 · sec H5 | Límite de organizaciones por usuario en create_organization (ligado a planes, T053) | product |
| T016 · orquestador | Platform admin recibe 403 en endpoints de org: hace falta la RPC public.effective_role(org_id) | db-architect (T017/T054) |
| T018 · sec H8 | La blocklist no es retroactiva: falta un job o vista para enlaces existentes que caen en un dominio bloqueado | security-reviewer / DQR-08 |
| T018 · ADR-0006 | T020: la API no envía el slug (lo genera la BD); slug.py solo valida el formato | backend-api |
