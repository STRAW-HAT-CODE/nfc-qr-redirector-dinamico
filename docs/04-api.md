# 4 · API

Base: `apps/api`. Autenticación: `Authorization: Bearer <JWT de Supabase>`. Organización activa: header `X-Org-Id`.

| Método y ruta | Rol mínimo | Descripción |
|---|---|---|
| `GET /r/{slug}` | público | 302 al destino; `?c=q\|n`, `&t={tag}` |
| `GET /healthz` | público | Estado de API y BD |
| `GET /v1/orgs` | autenticado | Mis organizaciones |
| `POST /v1/orgs` | autenticado | Crear org (creador = owner) |
| `GET /v1/orgs/{org}/members` | admin | Listar miembros |
| `POST /v1/orgs/{org}/members` | admin | Invitar |
| `PATCH /v1/orgs/{org}/members/{user}` | admin | Cambiar rol |
| `DELETE /v1/orgs/{org}/members/{user}` | admin | Quitar |
| `GET /v1/links` | viewer | Listar (búsqueda, estado, paginación) |
| `POST /v1/links` | editor | Crear |
| `GET /v1/links/{id}` | viewer | Detalle |
| `PATCH /v1/links/{id}` | editor | Nombre, estado, vigencia, fallback |
| `DELETE /v1/links/{id}` | admin | Archivar |
| `PATCH /v1/links/{id}/destination` | editor | Cambiar destino (genera historial) |
| `GET /v1/links/{id}/history` | viewer | Historial de destinos |
| `GET /v1/links/{id}/design` · `PUT` | viewer · editor | Diseño del QR |
| `GET /v1/links/{id}/qr.{png,svg,pdf}` | viewer | Descarga (`?size=`, `?template=`) |
| `GET /v1/links/{id}/nfc-tags` · `POST` | viewer · editor | Tags NFC |
| `GET /v1/links/{id}/stats` | viewer | `from`, `to`, `group=day\|channel\|country\|device` |
| `GET /v1/orgs/{org}/stats` | viewer | Métricas de la organización |
| `/v1/admin/orgs` | platform admin | Clientes, planes, suspensión |

## Errores
JSON `{ "error": { "code": "link_not_found", "message": "…" } }`. Códigos: 400 validación, 401 sin token, 403 sin permiso, 404, 409 conflicto (slug), 422, 429 rate limit.

## Redirector
| Situación | Respuesta |
|---|---|
| Activo y vigente | 302 → destination_url |
| Pausado, vencido o no iniciado | 302 → fallback_url, o página "no disponible" (200) |
| Org suspendida | Página "no disponible" |
| Slug inexistente | 404 con página amable |
