# DQR-10 · Infraestructura y deploy

| Campo | Valor |
|---|---|
| Depende de | DQR-00 |
| Agente líder | devops |
| Sprint | S4 |
| Tareas | DQR-T012, DQR-T055, DQR-T056, DQR-T058 |

## Alcance
Supabase staging/producción, Vercel (web + API), dominio corto, observabilidad y backups.

## Criterios de aceptación
- Preview por PR y producción desde `main`.
- `/r` responde en el dominio corto.
- Alertas de caída y latencia; backups verificados.
- Smoke en producción verde.

## Archivos esperados
- `.env.example`
- `vercel.json`
- `docs/07-deploy.md`

## Referencias
- docs/03-modelo-datos.md · docs/04-api.md · AGENTS.md
