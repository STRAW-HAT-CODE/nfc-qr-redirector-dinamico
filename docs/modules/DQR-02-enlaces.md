# DQR-02 · Enlaces dinámicos

| Campo | Valor |
|---|---|
| Depende de | DQR-01 |
| Agente líder | backend-api |
| Sprint | S1 |
| Tareas | DQR-T018, DQR-T019, DQR-T020 |

## Alcance
CRUD de enlaces con slug inmutable, destino editable, estados, vigencia, fallback e historial.

## Criterios de aceptación
- Slug base62 de 7 caracteres, único, no editable.
- Cambiar destino crea fila en `link_destination_history`.
- Destino solo http/https y pasa `url_policy`.
- Permisos por rol según docs/03-modelo-datos.md.

## Archivos esperados
- `supabase/migrations/*_links.sql`
- `apps/api/app/services/slug.py`
- `apps/api/app/services/url_policy.py`
- `apps/api/app/routers/links.py`

## Referencias
- docs/03-modelo-datos.md · docs/04-api.md · AGENTS.md
