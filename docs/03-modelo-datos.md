# 3 · Modelo de datos (Supabase / Postgres)

Toda tabla de negocio lleva `org_id` y RLS. Helpers: `is_org_member(org_id)`, `has_org_role(org_id, min_role)`, `is_platform_admin()`.

| Tabla | Campos | Notas |
|---|---|---|
| `organizations` | id uuid, name, slug unique, plan, status (active/suspended), limits jsonb, created_at | |
| `memberships` | org_id, user_id → auth.users, role (owner/admin/editor/viewer), created_at | PK (org_id, user_id); al menos un owner |
| `platform_admins` | user_id | Solo modificable por service role |
| `dynamic_links` | id uuid, org_id, slug unique, name, destination_url, fallback_url, status (active/paused/archived), starts_at, expires_at, created_by, created_at, updated_at | slug inmutable (trigger) |
| `link_destination_history` | id, link_id, old_url, new_url, changed_by, changed_at | Trigger al cambiar destination_url |
| `qr_designs` | link_id PK, fg, bg, logo_path, frame, ecc_level, style jsonb, updated_at | Logo en bucket privado `logos/{org_id}/` |
| `nfc_tags` | id, link_id, org_id, label, location, uid, created_at | |
| `scan_events` | id bigint identity, link_id, org_id, channel (qr/nfc/direct), tag_id, occurred_at, country, device, os, browser, referer, ip_hash, is_bot | Insert solo service role; índices (link_id, occurred_at) |
| `scan_daily_rollups` | link_id, org_id, day, scans, unique_visitors | PK (link_id, day); pg_cron |
| `audit_log` | id, org_id, actor, action, entity, entity_id, diff jsonb, at | |

## Permisos (RLS)
| Acción | viewer | editor | admin | owner | platform admin |
|---|---|---|---|---|---|
| Leer enlaces, diseños, NFC, métricas | ✓ | ✓ | ✓ | ✓ | ✓ |
| Crear/editar enlaces, diseños, NFC | | ✓ | ✓ | ✓ | ✓ |
| Archivar/borrar enlaces | | | ✓ | ✓ | ✓ |
| Gestionar miembros | | | ✓ | ✓ | ✓ |
| Borrar organización | | | | ✓ | ✓ |
| Suspender org/enlace, planes | | | | | ✓ |
