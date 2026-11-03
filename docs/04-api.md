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
| `GET /v1/orgs/{org}/stats` | viewer | Métricas de la organización (rollups diarios) |
| `GET /v1/me` | autenticado | Datos del usuario actual, rol en orgs, `is_platform_admin` |
| `GET /v1/admin/orgs` | platform admin | Listar orgs (búsqueda, paginación, 30d scans) |
| `PATCH /v1/admin/orgs/{org}` | platform admin | Cambiar plan, límites, estado (suspender), bloqueo de dominio |
| `POST /v1/admin/blocked-domains` | platform admin | Bloquear dominio |
| `DELETE /v1/admin/blocked-domains` | platform admin | Desbloquear (dominio en cuerpo) |
| `PATCH /v1/admin/links/{id}/status` | platform admin | Suspender/reactivar enlace |
| RPC `public.am_i_platform_admin()` | autenticado | `true` si es platform admin |
| RPC `public.my_effective_role(org_id)` | autenticado | Rol en esa org (`owner/admin/editor/viewer/null`) |

## Diseño del QR

`PUT /v1/links/{id}/design` acepta `style` (JSONB; lista blanca):

| Clave | Valores | Notas |
|---|---|---|
| `logo_preset` | `"google"` \| `null` | Logo incluido; fuerza ECC H. |
| `bg_transparent` | booleano | PNG/SVG transparentes; el PDF mantiene blanco. |
| `image_mode` | `none` \| `tint` \| `silhouette` \| `halftone` \| `photo` | Usa la imagen subida (`logo_path`) como relleno. `none` = logo centrado. |
| `image_intensity` | `0.0…1.0` | Aclara las celdas claras / umbral de silueta. |
| `image_contrast` | `0.5…2.0` | Contraste aplicado antes de componer. |

- `image_mode ≠ none` fuerza `ecc_level = H`, fondo opaco e ignora `logo_preset`; no se dibuja el logo central.
- `logo_path` sigue siendo el único origen de la imagen (bucket `logos`, PNG ≤ 1 MB); no hay endpoint, bucket ni migración nuevos.
- `GET /design` devuelve `image_mode` y el `style` crudo. Un cliente que no envía las claves de imagen conserva el modo guardado.
- En SVG, el modo imagen se rasteriza y se incrusta como `<image href="data:image/png;base64,…">` (autocontenido). El QR limpio sigue siendo vectorial.
- Las plantillas imprimibles (`?template=sticker|display|poster|google_review`) usan el logo centrado; el modo imagen solo aplica a `qr.{png,svg,pdf}` sin plantilla.

```json
{
  "fg": "#000000",
  "bg": "#ffffff",
  "style": {
    "module_style": "dots",
    "margin": 4,
    "image_mode": "halftone",
    "image_intensity": 0.8,
    "image_contrast": 1.0
  }
}
```

## Errores
JSON `{ "error": { "code": "error_code", "message": "…" } }`. Códigos:
- **2xx:** `200` OK · `201` Created
- **4xx:** `400` validación (p. ej. slug inválido) · `401` sin token · `403` sin permiso (`insufficient_role`, `not_platform_admin`, `link_suspended`) · `404` no encontrado · `409` conflicto (`slug_taken`, `org_limit_reached`) · `413` cuerpo demasiado grande · `422` semántica inválida (p. ej. plan no existe) · `429` rate limit (`plan_limit_reached`, `org_limit_reached`)
- **5xx:** `502` backend (upstream error) · `503` servicio no disponible (BD caída, timeout)

## Redirector
| Situación | Respuesta |
|---|---|
| Activo y vigente | 302 → destination_url, `Cache-Control: no-store` |
| Pausado, vencido o no iniciado | 302 → fallback_url, o página "no disponible" (200) |
| Suspendido (platform admin) | Página "no disponible" (200), sin fallback |
| Org suspendida | Página "no disponible" (200) |
| Slug inexistente | 404 con página amable, `Cache-Control: no-store` |
| Error de BD o timeout | 503 genérico, `Cache-Control: no-store` |
