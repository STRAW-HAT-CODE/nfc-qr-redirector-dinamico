-- =============================================================================
-- DQR-T013 · Tenancy: organizations, memberships, platform_admins + RLS helpers
-- Módulo DQR-01 · ADR-0001 (multi-tenant) · docs/03-modelo-datos.md
--
-- Fase: EXPAND (solo crea objetos nuevos; no hay datos previos).
--
-- Decisiones:
--   * Los helpers RLS viven en el schema `private` (no expuesto por PostgREST),
--     así no son invocables como RPC. `authenticated` tiene USAGE + EXECUTE
--     porque las políticas se evalúan con los privilegios del invocador.
--   * Nadie crea organizaciones con INSERT directo: solo vía la RPC
--     public.create_organization(), que inserta la org y la membresía owner
--     en la misma transacción.
--   * plan / status / limits / slug solo los cambia un platform admin o el
--     backend con service role (trigger guard). id y created_at son inmutables.
--   * Anti-escalada: solo un owner (o platform admin) puede asignar el rol
--     owner o modificar/quitar una membresía owner. Un admin gestiona
--     viewer/editor/admin.
--   * Siempre queda al menos un owner por organización (trigger), salvo
--     cuando se borra la organización completa (cascade).
-- =============================================================================

-- -----------------------------------------------------------------------------
-- Schema privado para helpers
-- -----------------------------------------------------------------------------
create schema if not exists private;
revoke all on schema private from public;
grant usage on schema private to authenticated, service_role;

-- -----------------------------------------------------------------------------
-- Tipos
-- -----------------------------------------------------------------------------
-- El orden de declaración define la jerarquía: viewer < editor < admin < owner.
create type public.org_role as enum ('viewer', 'editor', 'admin', 'owner');
create type public.org_status as enum ('active', 'suspended');

-- -----------------------------------------------------------------------------
-- Tablas
-- -----------------------------------------------------------------------------
create table public.organizations (
  id          uuid primary key default gen_random_uuid(),
  name        text not null,
  slug        text not null,
  plan        text not null default 'free',
  status      public.org_status not null default 'active',
  limits      jsonb not null default '{}'::jsonb,
  created_at  timestamptz not null default now(),
  constraint organizations_slug_key unique (slug),
  constraint organizations_name_check
    check (char_length(btrim(name)) between 1 and 120),
  -- 3..63 caracteres, minúsculas/dígitos/guion, sin guion al inicio o final.
  constraint organizations_slug_check
    check (slug ~ '^[a-z0-9][a-z0-9-]{1,61}[a-z0-9]$'),
  -- Catálogo de planes aún no definido en la spec: solo se valida el formato.
  constraint organizations_plan_check
    check (plan ~ '^[a-z][a-z0-9_]{0,31}$'),
  constraint organizations_limits_check
    check (jsonb_typeof(limits) = 'object')
);
comment on table public.organizations is 'Tenants (clientes de Monky). DQR-01.';

create table public.memberships (
  org_id      uuid not null references public.organizations (id) on delete cascade,
  user_id     uuid not null references auth.users (id) on delete cascade,
  role        public.org_role not null,
  created_at  timestamptz not null default now(),
  constraint memberships_pkey primary key (org_id, user_id)
);
comment on table public.memberships is 'Usuario ↔ organización con rol. Siempre ≥ 1 owner por org. DQR-01.';

-- La PK (org_id, user_id) cubre las búsquedas por org_id; user_id necesita índice
-- propio (FK + políticas "mis membresías").
create index memberships_user_id_idx on public.memberships (user_id);

create table public.platform_admins (
  user_id     uuid primary key references auth.users (id) on delete cascade,
  created_at  timestamptz not null default now()
);
comment on table public.platform_admins is 'Administradores de plataforma (Monky). Solo service role.';

-- -----------------------------------------------------------------------------
-- Helpers RLS (SECURITY DEFINER, STABLE, search_path vacío)
-- -----------------------------------------------------------------------------
create or replace function private.is_org_member(p_org_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
    from public.memberships m
    where m.org_id = p_org_id
      and m.user_id = (select auth.uid())
  );
$$;

create or replace function private.has_org_role(p_org_id uuid, p_min_role public.org_role)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
    from public.memberships m
    where m.org_id = p_org_id
      and m.user_id = (select auth.uid())
      and m.role >= p_min_role
  );
$$;

create or replace function private.is_platform_admin()
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
    from public.platform_admins pa
    where pa.user_id = (select auth.uid())
  );
$$;

revoke execute on function private.is_org_member(uuid) from public, anon;
revoke execute on function private.has_org_role(uuid, public.org_role) from public, anon;
revoke execute on function private.is_platform_admin() from public, anon;
grant execute on function private.is_org_member(uuid) to authenticated, service_role;
grant execute on function private.has_org_role(uuid, public.org_role) to authenticated, service_role;
grant execute on function private.is_platform_admin() to authenticated, service_role;

-- -----------------------------------------------------------------------------
-- Triggers de integridad
-- -----------------------------------------------------------------------------

-- organizations: columnas privilegiadas e inmutables.
-- Convención: ninguna RPC SECURITY DEFINER debe escribir plan/status/limits/slug
-- a partir de la entrada del usuario (se saltaría esta guarda).
-- SECURITY INVOKER a propósito: current_user es el rol real de la petición.
create or replace function private.organizations_guard()
returns trigger
language plpgsql
security invoker
set search_path = ''
as $$
begin
  if new.id is distinct from old.id or new.created_at is distinct from old.created_at then
    raise exception 'organizations.id y created_at son inmutables'
      using errcode = '42501';
  end if;

  -- Solo se restringe a roles de usuario final; service_role/postgres pasan.
  if current_user in ('authenticated', 'anon')
     and (new.plan   is distinct from old.plan
       or new.status is distinct from old.status
       or new.limits is distinct from old.limits
       or new.slug   is distinct from old.slug)
     and not private.is_platform_admin()
  then
    raise exception 'Solo un platform admin puede cambiar plan, status, limits o slug'
      using errcode = '42501';
  end if;

  return new;
end;
$$;

create trigger organizations_guard
  before update on public.organizations
  for each row execute function private.organizations_guard();

-- memberships: al menos un owner por organización.
create or replace function private.memberships_keep_last_owner()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if old.role <> 'owner' then
    return coalesce(new, old);
  end if;

  if tg_op = 'UPDATE' and new.role = 'owner' and new.org_id = old.org_id then
    return new;
  end if;

  -- Serializa cambios de owners por org. Si la org ya no existe (borrado en
  -- cascada de la organización) no hay nada que proteger.
  perform 1 from public.organizations o where o.id = old.org_id for update;
  if not found then
    return coalesce(new, old);
  end if;

  -- En REPEATABLE READ la snapshot es antigua y el lock sobre la org no
  -- detecta cambios concurrentes de owners: se rechaza explícitamente.
  -- READ COMMITTED (lock + snapshot nueva) y SERIALIZABLE (SSI) son seguros.
  if current_setting('transaction_isolation') = 'repeatable read' then
    raise exception 'Quitar o degradar un owner requiere READ COMMITTED o SERIALIZABLE'
      using errcode = '0A000', hint = 'last_owner_isolation';
  end if;

  if not exists (
    select 1
    from public.memberships m
    where m.org_id = old.org_id
      and m.role = 'owner'
      and m.user_id <> old.user_id
  ) then
    raise exception 'No se puede quitar ni degradar al último owner de la organización'
      using errcode = 'P0001', hint = 'last_owner';
  end if;

  return coalesce(new, old);
end;
$$;

create trigger memberships_keep_last_owner
  before update or delete on public.memberships
  for each row execute function private.memberships_keep_last_owner();

revoke execute on function private.organizations_guard() from public, anon;
revoke execute on function private.memberships_keep_last_owner() from public, anon, authenticated;

-- -----------------------------------------------------------------------------
-- RPC: crear organización (creador = owner, atómico)
-- -----------------------------------------------------------------------------
create or replace function public.create_organization(p_name text, p_slug text)
returns public.organizations
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_uid uuid := (select auth.uid());
  v_org public.organizations;
begin
  if v_uid is null then
    raise exception 'Autenticación requerida' using errcode = '42501';
  end if;

  insert into public.organizations (name, slug)
  values (btrim(p_name), lower(btrim(p_slug)))
  returning * into v_org;

  insert into public.memberships (org_id, user_id, role)
  values (v_org.id, v_uid, 'owner');

  return v_org;
end;
$$;

revoke execute on function public.create_organization(text, text) from public, anon;
grant execute on function public.create_organization(text, text) to authenticated;

-- -----------------------------------------------------------------------------
-- Privilegios de tabla (explícitos; RLS filtra filas)
-- -----------------------------------------------------------------------------
revoke all on public.organizations from anon, authenticated;
revoke all on public.memberships from anon, authenticated;
revoke all on public.platform_admins from anon, authenticated;

-- Sin INSERT: las orgs se crean con create_organization().
grant select, update, delete on public.organizations to authenticated;
-- INSERT por columnas (created_at no falsificable); solo el rol es editable.
grant select, delete on public.memberships to authenticated;
grant insert (org_id, user_id, role) on public.memberships to authenticated;
grant update (role) on public.memberships to authenticated;

grant all on public.organizations, public.memberships, public.platform_admins to service_role;

-- -----------------------------------------------------------------------------
-- RLS
-- -----------------------------------------------------------------------------
alter table public.organizations enable row level security;
alter table public.memberships enable row level security;
alter table public.platform_admins enable row level security;
-- platform_admins: sin políticas → authenticated/anon no ven ni tocan nada;
-- solo service role (bypassrls).

-- organizations ---------------------------------------------------------------
create policy organizations_select
  on public.organizations for select
  to authenticated
  using (
    private.is_org_member(id)
    or (select private.is_platform_admin())
  );

create policy organizations_update
  on public.organizations for update
  to authenticated
  using (
    private.has_org_role(id, 'admin')
    or (select private.is_platform_admin())
  )
  with check (
    private.has_org_role(id, 'admin')
    or (select private.is_platform_admin())
  );

create policy organizations_delete
  on public.organizations for delete
  to authenticated
  using (
    private.has_org_role(id, 'owner')
    or (select private.is_platform_admin())
  );

-- memberships -----------------------------------------------------------------
-- Cada usuario ve sus propias membresías; admin+ ve todas las de su org.
create policy memberships_select
  on public.memberships for select
  to authenticated
  using (
    user_id = (select auth.uid())
    or private.has_org_role(org_id, 'admin')
    or (select private.is_platform_admin())
  );

-- admin+ añade miembros; solo owner puede crear otro owner.
create policy memberships_insert
  on public.memberships for insert
  to authenticated
  with check (
    (select private.is_platform_admin())
    or (
      private.has_org_role(org_id, 'admin')
      and (role <> 'owner' or private.has_org_role(org_id, 'owner'))
    )
  );

-- admin+ cambia roles; tocar a un owner o promover a owner exige ser owner.
create policy memberships_update
  on public.memberships for update
  to authenticated
  using (
    (select private.is_platform_admin())
    or (
      private.has_org_role(org_id, 'admin')
      and (role <> 'owner' or private.has_org_role(org_id, 'owner'))
    )
  )
  with check (
    (select private.is_platform_admin())
    or (
      private.has_org_role(org_id, 'admin')
      and (role <> 'owner' or private.has_org_role(org_id, 'owner'))
    )
  );

-- admin+ quita miembros; quitar a un owner exige ser owner.
create policy memberships_delete
  on public.memberships for delete
  to authenticated
  using (
    (select private.is_platform_admin())
    or (
      private.has_org_role(org_id, 'admin')
      and (role <> 'owner' or private.has_org_role(org_id, 'owner'))
    )
  );
