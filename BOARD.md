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
| DQR-T014 | Tests RLS tenancy | qa | DONE (tenancy_test.sql, 66 tests) | T013 |
| DQR-T015 | Revisión seguridad S1 | security-reviewer | DONE (cerrada en T057: sin críticas ni altas abiertas) | T013, T018, T021, T022 |
| DQR-T016 | Auth FastAPI (JWT) | backend-api | DONE (qa PASS) | T010, T013 |
| DQR-T017 | API orgs y miembros | backend-api | DONE (qa PASS) | T016 |
| DQR-T018 | Migración dynamic_links + historial | db-architect | DONE (qa PASS · seguridad APPROVED) | T013 |
| DQR-T019 | Slug + política de URLs | backend-api | DONE (qa PASS) | T010 |
| DQR-T020 | API CRUD enlaces | backend-api | DONE (qa PASS) | T016, T018, T019 |
| DQR-T021 | Redirector /r/{slug} | backend-api | DONE (qa PASS · seguridad APPROVED) | T018 |
| DQR-T022 | Migración scan_events | db-architect | DONE (qa PASS · seguridad APPROVED · #12) | T018 |
| DQR-T023 | Registro asíncrono del escaneo | backend-api | DONE (qa PASS · seguridad APPROVED) | T021, T022 |
| DQR-T024 | Tests S1 | qa | DONE (qa PASS · huecos cubiertos en #42) | T020, T023 |

## Sprint 2 — QR y NFC
| ID | Tarea | Agente | Estado | Dependencias |
|---|---|---|---|---|
| DQR-T030 | Servicio generación QR | qr-nfc | DONE (qa PASS) | T020 |
| DQR-T031 | Migración qr_designs + bucket | db-architect | DONE (qa PASS · seguridad APPROVED) | T018 |
| DQR-T032 | API diseño y descargas | qr-nfc | DONE (qa PASS · seguridad APPROVED) | T030, T031 |
| DQR-T033 | Plantillas + Canva | qr-nfc | DONE (qa PASS) | T032 |
| DQR-T034 | Migración nfc_tags | db-architect | DONE (qa PASS · seguridad APPROVED) | T018 |
| DQR-T035 | API NFC + guía | qr-nfc | DONE (qa PASS) | T034, T021 |
| DQR-T036 | Tests de QR | qa | DONE (qa PASS) | T032 |

## Sprint 3 — Analytics y dashboard
| ID | Tarea | Agente | Estado | Dependencias |
|---|---|---|---|---|
| DQR-T040 | Enriquecimiento + bots | analytics | DONE (qa PASS) | T023 |
| DQR-T041 | Rollups pg_cron | db-architect | DONE (qa PASS · seguridad APPROVED) | T022 |
| DQR-T042 | Endpoints de métricas | analytics | DONE (qa PASS · perf de org_breakdown en backlog) | T040, T041 |
| DQR-T043 | Next.js base + auth | frontend | DONE (qa PASS) | T010, T017 |
| DQR-T044 | Pantallas de enlaces | frontend | DONE (qa PASS) | T043, T020 |
| DQR-T045 | Diseñador de QR | frontend | DONE (qa PASS) | T044, T032 |
| DQR-T046 | Pantalla NFC | frontend | DONE (qa PASS) | T044, T035 |
| DQR-T047 | Analytics UI | frontend | DONE (qa PASS · cubierto por E2E) | T042, T044 |
| DQR-T048 | Miembros UI | frontend | DONE (qa PASS) | T043 |
| DQR-T049 | E2E Playwright | qa | DONE (E2E PASS contra staging, limpieza verificada) | T045, T047 |

## Extra (petición del usuario)
| ID | Tarea | Agente | Estado | Dependencias |
|---|---|---|---|---|
| DQR-T063 | Eliminar enlace definitivamente (admin+, con confirmación) | backend-api + frontend | DONE (PR #55/#56 · en producción) | T020, T044 |
| DQR-T064 | Diseño de QR por defecto: logo Google, puntos, ojos cuadrados, fondo transparente | qr-nfc | DONE (PR #57 · en producción) | T032, T060, T061 |
| DQR-T065 | QR artístico: imagen de fondo (tinte, silueta, halftone, foto) reutilizando `logo_path` | qr-nfc + frontend | TESTING (PR #58 · en producción · falta escaneo en celulares) | T032, T045, T060, T061 |
| DQR-T061 | Fondo transparente + plantillas de impresión conectadas (fuente con acentos) | qr-nfc + frontend | DONE (PR #50–#53 · en producción) | T060 |
| DQR-T060 | Preset "Reseñas de Google" (logo G + plantilla) | qr-nfc + frontend | DONE (PR #47/#48 · en producción) | T032, T045 |

## Sprint 4 — Seguridad, plataforma, producción
| ID | Tarea | Agente | Estado | Dependencias |
|---|---|---|---|---|
| DQR-T050 | Rate limiting | backend-api | DONE (qa PASS) | T023 |
| DQR-T051 | Política de URLs / abuso | security-reviewer | DONE (qa PASS · seguridad APPROVED) | T020 |
| DQR-T052 | audit_log | db-architect | DONE (qa PASS · seguridad APPROVED) | T018 |
| DQR-T053 | Planes y límites | db-architect | DONE (qa PASS · seguridad APPROVED) | T013 |
| DQR-T054 | Consola Monky | frontend | DONE (qa PASS) | T043, T053 |
| DQR-T055 | Deploy Vercel + dominio | devops | DONE (prod: dqr-web.vercel.app + dqr-api.vercel.app · Supabase nfc-redirect-api) | T011 |
| DQR-T056 | Observabilidad | devops | DONE (qa PASS · pulido en curso) | T055 |
| DQR-T057 | Auditoría pre-lanzamiento | security-reviewer | DONE (GO: B1–B5 y N1 cerrados; advisors prod sin errores; leaked password protection activa) | T050–T052, T054 |
| DQR-T058 | Regresión + smoke prod | qa | DONE (smoke prod OK: healthz db ok, /r 404, web 200 con cabeceras; platform admin dado de alta) | T055, T057 |

## Backlog abierto por revisiones
| Origen | Pendiente | Decide |
|---|---|---|
| T013 · sec H4 | Flujo para borrar la cuenta del último owner (transferir la propiedad o borrar la org) | product |
| T013 · sec H5 | Límite de organizaciones por usuario en create_organization (ligado a planes, T053) | product |
| T016 · orquestador | Platform admin recibe 403 en endpoints de org: hace falta la RPC public.effective_role(org_id) | db-architect (T017/T054) |
| T018 · sec H8 | La blocklist no es retroactiva: falta un job o vista para enlaces existentes que caen en un dominio bloqueado | security-reviewer / DQR-08 |
| T018 · ADR-0006 | T020: la API no envía el slug (lo genera la BD); slug.py solo valida el formato | backend-api |
| T017 · orquestador | Añadir miembro por email (hoy 501): RPC para resolver email a user_id sin enumeración | db-architect + backend-api |
| T023 · sec H2 | Sal de ip_hash con rotación real (hoy: secreto fijo + fecha) | backend-api / T040 |
| T031 · sec H2 | Cuota de logos por org (Storage) | db-architect / T053 |
| T042 · qa | org_breakdown (country/device) ~1,2 s con 500k eventos/90 días: rollups por dimensión o caché | db-architect / V2 |
