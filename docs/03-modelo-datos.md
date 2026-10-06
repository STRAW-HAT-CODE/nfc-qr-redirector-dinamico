# 3 · Modelo de datos (Supabase / Postgres)

Toda tabla de negocio lleva `org_id` y RLS. Helpers: `is_org_member(org_id)`, `has_org_role(org_id, min_role)`, `is_platform_admin()`. RPC públicas: `create_organization`, `record_scan`, `resolve_link`, `am_i_platform_admin`, `my_effective_role`, `link_stats`, `org_stats`, `admin_*` (8 funciones de plataforma).

| Tabla | Campos | Notas |
|---|---|---|
| `organizations` | id uuid, name, slug unique, plan FK→plans(code), status (active/suspended), limits jsonb, created_at, updated_at | slug inmutable (trigger); plan/status/limits solo platform admin |
| `memberships` | org_id, user_id → auth.users, role (owner/admin/editor/viewer), created_at | PK (org_id, user_id); al menos un owner; trigger lo impone |
| `platform_admins` | user_id → auth.users | Solo modificable por service role |
| `dynamic_links` | id uuid, org_id, slug unique, name, destination_url, fallback_url, status (active/paused/archived/suspended_at), starts_at, expires_at, created_by, created_at, updated_at | slug inmutable (trigger); suspended_at solo platform admin; CHECKs de URL |
| `link_destination_history` | id, link_id, org_id, old_url, new_url, changed_by, changed_at | Trigger al cambiar destination_url |
| `qr_designs` | link_id PK, org_id, fg, bg, logo_path, frame, ecc_level, style jsonb, updated_at | Logo en bucket privado `logos/{org_id}/{link_id}-uuid.png`; ECC H forzado con logo |
| `nfc_tags` | id uuid, link_id, org_id, uid unique per org, label, location, created_at | RLS: viewer lee, editor crea/edita, admin+ borra |
| `scan_events` | id bigint identity, link_id, org_id, channel (qr/nfc/direct), tag_id, occurred_at, country, device, os, browser, referer, ip_hash, is_bot | Insert solo service role (RPC); índices (link_id, occurred_at desc), (org_id, occurred_at desc), BRIN |
| `scan_daily_rollups` | link_id, org_id, day date, scans, unique_visitors, closed_through | PK (link_id, day); actualizado por pg_cron cada 15 min |
| `audit_log` | id bigint, org_id, actor uuid, action, entity, entity_id, diff jsonb, at timestamptz | Append-only; lectura admin+ y platform admin; conforme a T018-H6 |
| `plans` (privada) | code, max_links, max_members, max_logos | Catálogo de planes (free, pro, business); seed idempotente |
| `slug_registry` (privada) | slug, org_id, created_at | Nunca reasigna un slug, incluso con service role |
| `blocked_domains` (privada) | domain, reason, blocked_at | Dominios bloqueados por platform admin |

## Permisos (RLS)
| Acción | viewer | editor | admin | owner | platform admin |
|---|---|---|---|---|---|
| Leer enlaces, diseños, NFC, métricas, auditoría | ✓ | ✓ | ✓ | ✓ | ✓ (todo) |
| Crear/editar enlaces, diseños, NFC | | ✓ | ✓ | ✓ | ✓ |
| Cambiar estado de enlace (active/paused/archived) | | ✓ | ✓ | ✓ | ✓ |
| Archivar/borrar enlaces | | | ✓ | ✓ | ✓ |
| Gestionar miembros (add/remove/change role) | | | ✓ | ✓ | ✓ |
| Borrar organización | | | | ✓ | ✓ |
| Suspender org/enlace (`suspended_at`, pausa efectiva) | | | | | ✓ |
| Cambiar plan/límites/slug | | | | | ✓ |
