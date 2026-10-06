# ADR-0006 · Controles de seguridad de enlaces también en la BD

- Estado: Aceptado
- Fecha: 2026-10-05
- Origen: revisión de seguridad de DQR-T018 (PR #7), hallazgos H1 y H3

## Contexto
La API consulta Postgres con el JWT del usuario para que RLS sea la barrera real (docs/02). Pero el JWT y la anon key son públicos para el cliente, así que cualquier miembro editor+ puede escribir directamente en `/rest/v1/dynamic_links` y saltarse los controles que solo viven en Python: la política de URLs (T019), la generación aleatoria del slug (T019) y los límites de plan (T053). Además, un slug borrado podía reasignarse a otra organización y secuestrar QR/NFC ya impresos.

## Decisión
Defensa en profundidad: todo control de **seguridad** sobre enlaces se aplica también en la BD; Python sigue siendo la primera línea con errores claros.
- **Slug:** lo genera la BD (base62 de 7, aleatorio); `authenticated` no puede insertarlo ni elegirlo. Un slug usado nunca se reasigna (`private.slug_registry`).
- **URLs:** CHECK/trigger en BD: solo http/https, sin credenciales (`user@`), sin caracteres de control, sin `localhost`/`.local`/`.internal` ni IPs literales privadas/loopback/link-local; blocklist de dominios en `private.blocked_domains` (gestionada por platform admin / service role).
- **Límites de plan:** trigger en BD cuando se implemente T053.
- La API mantiene el JWT del usuario (sin service role para escrituras de negocio).

## Alternativas descartadas
- Quitar INSERT/UPDATE a `authenticated` y escribir con service role desde la API: RLS dejaría de ser la barrera real; un bug de autorización en la API expondría todos los tenants.
- No exponer las tablas en la Data API: el dashboard y la API usan PostgREST con el JWT del usuario.

## Consecuencias
- Hay validación duplicada en Python y SQL; los tests de ambos lados deben cubrir los mismos casos de bypass.
- `slug.py` queda para validar formato y para tests; la API no envía el slug al crear un enlace.
