-- =============================================================================
-- DQR-T051 / DQR-T054 (BD) · RPC de la consola de plataforma Monky
-- Módulo DQR-09 · ADR-0006 · docs/04-api.md (/v1/admin/*) · BOARD backlog T016
-- (el platform admin recibía 403 en endpoints de org → my_effective_role).
--
-- Fase: EXPAND (solo crea funciones nuevas; no toca tablas ni datos).
--
-- Contrato (lo fija el orquestador; lo consumen backend y frontend):
--   my_effective_role(org)          rol efectivo del usuario en la org
--   admin_list_orgs(q, limit, off)  orgs con uso (miembros, enlaces, escaneos 30 d)
--   admin_update_org(org, plan, status, limits)
--   admin_list_blocked_domains() · admin_block_domain(d) · admin_unblock_domain(d)
--   admin_set_link_status(link, status) · admin_find_link(slug)
--
-- Decisiones:
--   * Todas las admin_* exigen private.is_platform_admin(); si no, 42501
--     (hint 'platform_admin_required'). SECURITY DEFINER con search_path ''.
--     EXECUTE solo para authenticated (sin anon ni service_role: service_role no
--     tiene auth.uid() y nunca sería platform admin).
--   * my_effective_role: 'owner' si es platform admin y la org existe; si no,
--     el rol de su membresía o NULL. No exige platform admin. Solo revela el
--     rol propio (lo mismo que ya ve por RLS en memberships).
--   * Escrituras como owner de la función (postgres): organizations_guard y
--     plan_limit_guard no restringen a ese rol, por eso cada RPC comprueba
--     platform admin ANTES de escribir. Los triggers de integridad
--     (dynamic_links_guard, CHECK, FK) y de auditoría siguen aplicando, y
--     audit_log.actor = auth.uid() = el platform admin.
--   * Auditoría:
--       - plan/status: trigger organizations_audit (T052).
--       - limits: organizations_audit no lo cubre (T052 lo excluye a
--         propósito y audit_test lo verifica), así que admin_update_org
--         escribe 'org.limits_changed' con diff {limits: {old, new}}.
--       - estado de enlace: trigger dynamic_links_audit (link.status_changed).
--       - blocklist: no pertenece a ninguna org y audit_log.org_id es NOT
--         NULL; se registra con org_id = UUID nulo
--         (00000000-0000-0000-0000-000000000000) = ámbito plataforma, entity
--         'blocked_domain', entity_id = dominio, acciones
--         blocked_domain.created / blocked_domain.deleted. Por RLS solo lo
--         ve un platform admin (ninguna org tiene ese id).
--       Escrituras directas de service_role a limits o blocked_domains siguen
--       sin auditarse (igual que antes de esta migración).
--   * No encontrado → P0002 (hint 'not_found'), para que la API devuelva 404.
--   * Dominios: lower + btrim de espacios y de puntos extremos; la validación
--     es el CHECK de private.blocked_domains (23514, hint 'invalid_domain').
--     No convierte IDN a punycode (lo hace la API). Bloquear un dominio ya
--     bloqueado es idempotente; desbloquear uno que no está → P0002.
--   * admin_list_orgs: q busca en name y slug (ILIKE, comodines escapados);
--     limit se acota a 1..200 (NULL → 50), offset ≥ 0. scans_30d = escaneos
--     humanos (is_bot = false) de scan_events en los últimos 30 días
--     (índice scan_events_org_occurred_idx), no los rollups, para incluir hoy.
--   * admin_set_link_status acepta cualquier link_status (active reactiva).
-- =============================================================================

-- -----------------------------------------------------------------------------
-- Helper: exige platform admin
-- -----------------------------------------------------------------------------
create or replace function private.assert_platform_admin()
returns void
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if not private.is_platform_admin() then
    raise exception 'Solo un platform admin puede usar esta función'
      using errcode = '42501', hint = 'platform_admin_required';
  end if;
end;
$$;

comment on function private.assert_platform_admin() is
  'Lanza 42501 (platform_admin_required) si auth.uid() no es platform admin. DQR-T051.';
-- Solo la llaman RPC SECURITY DEFINER (owner postgres).
revoke execute on function private.assert_platform_admin() from public, anon, authenticated;

-- Normaliza un dominio para la blocklist: minúsculas, sin espacios ni puntos extremos.
create or replace function private.normalize_domain(p_domain text)
returns text
language sql
immutable
set search_path = ''
as $$
  select nullif(btrim(lower(btrim(p_domain)), '.'), '');
$$;

revoke execute on function private.normalize_domain(text) from public, anon, authenticated;

-- -----------------------------------------------------------------------------
-- Rol efectivo (lo usa require_role en la API)
-- -----------------------------------------------------------------------------
create or replace function public.my_effective_role(p_org_id uuid)
returns public.org_role
language sql
stable
security definer
set search_path = ''
as $$
  select case
    when private.is_platform_admin()
         and exists (select 1 from public.organizations o where o.id = p_org_id)
      then 'owner'::public.org_role
    else (
      select m.role
      from public.memberships m
      where m.org_id = p_org_id
        and m.user_id = (select auth.uid())
    )
  end;
$$;

comment on function public.my_effective_role(uuid) is
  'Rol efectivo de auth.uid() en la org: owner si es platform admin (y la org existe); si no, su rol o NULL. DQR-T051.';

-- -----------------------------------------------------------------------------
-- Organizaciones
-- -----------------------------------------------------------------------------
create or replace function public.admin_list_orgs(
  p_q      text default null,
  p_limit  int  default 50,
  p_offset int  default 0
)
returns table (
  id          uuid,
  name        text,
  slug        text,
  plan        text,
  status      public.org_status,
  limits      jsonb,
  created_at  timestamptz,
  members     bigint,
  links       bigint,
  scans_30d   bigint
)
language plpgsql
stable
security definer
set search_path = ''
as $$
#variable_conflict use_column
declare
  v_q      text := nullif(btrim(p_q), '');
  v_like   text;
  v_limit  int  := least(greatest(coalesce(p_limit, 50), 1), 200);
  v_offset int  := greatest(coalesce(p_offset, 0), 0);
  v_since  timestamptz := now() - interval '30 days';
begin
  perform private.assert_platform_admin();

  if v_q is not null then
    v_like := '%' || replace(replace(replace(v_q, '\', '\\'), '%', '\%'), '_', '\_') || '%';
  end if;

  return query
  select o.id, o.name, o.slug, o.plan, o.status, o.limits, o.created_at,
         (select count(*) from public.memberships m where m.org_id = o.id),
         (select count(*) from public.dynamic_links l where l.org_id = o.id),
         (select count(*) from public.scan_events e
           where e.org_id = o.id and not e.is_bot and e.occurred_at >= v_since)
  from public.organizations o
  where v_like is null
     or o.name ilike v_like
     or o.slug ilike v_like
  order by o.created_at desc, o.id
  limit v_limit
  offset v_offset;
end;
$$;

comment on function public.admin_list_orgs(text, int, int) is
  'Consola Monky: orgs con uso (miembros, enlaces, escaneos humanos 30 d). Solo platform admin. DQR-T054.';

create or replace function public.admin_update_org(
  p_org_id uuid,
  p_plan   text              default null,
  p_status public.org_status default null,
  p_limits jsonb             default null
)
returns public.organizations
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_old public.organizations;
  v_org public.organizations;
begin
  perform private.assert_platform_admin();

  select * into v_old from public.organizations o where o.id = p_org_id for update;
  if not found then
    raise exception 'Organización no encontrada'
      using errcode = 'P0002', hint = 'not_found';
  end if;

  -- plan: FK a plans (23503); limits: organizations_limits_format_check (23514).
  -- plan/status los audita el trigger organizations_audit.
  update public.organizations o
     set plan   = coalesce(p_plan, o.plan),
         status = coalesce(p_status, o.status),
         limits = coalesce(p_limits, o.limits)
   where o.id = p_org_id
  returning * into v_org;

  if v_org.limits is distinct from v_old.limits then
    insert into public.audit_log (org_id, action, entity, entity_id, diff)
    values (v_org.id, 'org.limits_changed', 'org', v_org.id::text,
            jsonb_build_object('limits',
              jsonb_build_object('old', v_old.limits, 'new', v_org.limits)));
  end if;

  return v_org;
end;
$$;

comment on function public.admin_update_org(uuid, text, public.org_status, jsonb) is
  'Consola Monky: cambia plan, status (suspender) y override de limits. Auditado. Solo platform admin. DQR-T054.';

-- -----------------------------------------------------------------------------
-- Blocklist de dominios
-- -----------------------------------------------------------------------------
create or replace function public.admin_list_blocked_domains()
returns table (domain text, created_at timestamptz)
language plpgsql
stable
security definer
set search_path = ''
as $$
#variable_conflict use_column
begin
  perform private.assert_platform_admin();

  return query
  select d.domain, d.created_at
  from private.blocked_domains d
  order by d.domain;
end;
$$;

comment on function public.admin_list_blocked_domains() is
  'Consola Monky: dominios bloqueados como destino. Solo platform admin. DQR-T051.';

create or replace function public.admin_block_domain(p_domain text)
returns void
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_domain text := private.normalize_domain(p_domain);
  v_added  text;
begin
  perform private.assert_platform_admin();

  if v_domain is null then
    raise exception 'Dominio no válido'
      using errcode = '23514', hint = 'invalid_domain';
  end if;

  begin
    insert into private.blocked_domains (domain) values (v_domain)
    on conflict (domain) do nothing
    returning domain into v_added;
  exception when check_violation then
    raise exception 'Dominio no válido: %', v_domain
      using errcode = '23514', hint = 'invalid_domain';
  end;

  if v_added is not null then
    insert into public.audit_log (org_id, action, entity, entity_id, diff)
    values ('00000000-0000-0000-0000-000000000000', 'blocked_domain.created',
            'blocked_domain', v_added,
            jsonb_build_object('domain', jsonb_build_object('old', null, 'new', v_added)));
  end if;
end;
$$;

comment on function public.admin_block_domain(text) is
  'Consola Monky: bloquea un dominio (y subdominios) como destino. Normaliza; idempotente. Auditado. DQR-T051.';

create or replace function public.admin_unblock_domain(p_domain text)
returns void
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_domain  text := private.normalize_domain(p_domain);
  v_removed text;
begin
  perform private.assert_platform_admin();

  delete from private.blocked_domains d
   where d.domain = v_domain
  returning d.domain into v_removed;

  if v_removed is null then
    raise exception 'Dominio no bloqueado'
      using errcode = 'P0002', hint = 'not_found';
  end if;

  insert into public.audit_log (org_id, action, entity, entity_id, diff)
  values ('00000000-0000-0000-0000-000000000000', 'blocked_domain.deleted',
          'blocked_domain', v_removed,
          jsonb_build_object('domain', jsonb_build_object('old', v_removed, 'new', null)));
end;
$$;

comment on function public.admin_unblock_domain(text) is
  'Consola Monky: quita un dominio de la blocklist (P0002 si no estaba). Auditado. DQR-T051.';

-- -----------------------------------------------------------------------------
-- Enlaces
-- -----------------------------------------------------------------------------
create or replace function public.admin_set_link_status(
  p_link_id uuid,
  p_status  public.link_status
)
returns public.dynamic_links
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_link public.dynamic_links;
begin
  perform private.assert_platform_admin();

  if p_status is null then
    raise exception 'Estado requerido'
      using errcode = '22023', hint = 'invalid_status';
  end if;

  -- Auditado por dynamic_links_audit (link.status_changed).
  update public.dynamic_links l
     set status = p_status
   where l.id = p_link_id
  returning * into v_link;

  if not found then
    raise exception 'Enlace no encontrado'
      using errcode = 'P0002', hint = 'not_found';
  end if;

  return v_link;
end;
$$;

comment on function public.admin_set_link_status(uuid, public.link_status) is
  'Consola Monky: cambia el estado de cualquier enlace (suspender = paused/archived). Auditado. DQR-T051.';

create or replace function public.admin_find_link(p_slug text)
returns table (
  id               uuid,
  org_id           uuid,
  org_name         text,
  slug             text,
  name             text,
  destination_url  text,
  status           public.link_status,
  created_at       timestamptz
)
language plpgsql
stable
security definer
set search_path = ''
as $$
#variable_conflict use_column
begin
  perform private.assert_platform_admin();

  return query
  select l.id, l.org_id, o.name, l.slug, l.name, l.destination_url, l.status, l.created_at
  from public.dynamic_links l
  join public.organizations o on o.id = l.org_id
  where l.slug = btrim(p_slug);
end;
$$;

comment on function public.admin_find_link(text) is
  'Consola Monky: busca un enlace por slug exacto en cualquier org. Solo platform admin. DQR-T051.';

-- -----------------------------------------------------------------------------
-- Privilegios: EXECUTE solo authenticated
-- -----------------------------------------------------------------------------
revoke execute on function public.my_effective_role(uuid) from public, anon, service_role;
revoke execute on function public.admin_list_orgs(text, int, int) from public, anon, service_role;
revoke execute on function public.admin_update_org(uuid, text, public.org_status, jsonb) from public, anon, service_role;
revoke execute on function public.admin_list_blocked_domains() from public, anon, service_role;
revoke execute on function public.admin_block_domain(text) from public, anon, service_role;
revoke execute on function public.admin_unblock_domain(text) from public, anon, service_role;
revoke execute on function public.admin_set_link_status(uuid, public.link_status) from public, anon, service_role;
revoke execute on function public.admin_find_link(text) from public, anon, service_role;

grant execute on function public.my_effective_role(uuid) to authenticated;
grant execute on function public.admin_list_orgs(text, int, int) to authenticated;
grant execute on function public.admin_update_org(uuid, text, public.org_status, jsonb) to authenticated;
grant execute on function public.admin_list_blocked_domains() to authenticated;
grant execute on function public.admin_block_domain(text) to authenticated;
grant execute on function public.admin_unblock_domain(text) to authenticated;
grant execute on function public.admin_set_link_status(uuid, public.link_status) to authenticated;
grant execute on function public.admin_find_link(text) to authenticated;
