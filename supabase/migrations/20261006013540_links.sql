-- =============================================================================
-- DQR-T018 · Enlaces dinámicos: dynamic_links + link_destination_history
-- Módulo DQR-02 · docs/03-modelo-datos.md · docs/04-api.md · docs/06-seguridad.md
--
-- Fase: EXPAND (solo crea objetos nuevos; depende de 20261006011844_tenancy.sql).
--
-- Decisiones:
--   * slug base62 de 7 caracteres, único y generado por la API (T019). Es
--     inmutable para todos los roles (trigger), incluido service_role.
--   * org_id, created_by, id y created_at también son inmutables. Única
--     excepción: created_by pasa a NULL cuando se borra el usuario en Auth
--     (FK on delete set null).
--   * destination_url / fallback_url: CHECK básico http/https; la validación
--     fuerte (url_policy, blocklist) vive en la API (T019).
--   * Permisos (matriz de docs/03): viewer lee; editor crea y edita; admin+
--     archiva, desarchiva y borra. Un enlace archivado solo lo modifica admin+.
--     Platform admin puede todo.
--   * link_destination_history lleva org_id (desnormalizado desde el enlace)
--     para cumplir "toda tabla de negocio lleva org_id" y para que su RLS no
--     necesite join. Solo lectura para miembros; la escribe un trigger
--     SECURITY DEFINER.
--   * public.resolve_link() es para el redirector (service_role). No se expone
--     a anon ni a authenticated.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- Tipos
-- -----------------------------------------------------------------------------
create type public.link_status as enum ('active', 'paused', 'archived');

-- -----------------------------------------------------------------------------
-- Tablas
-- -----------------------------------------------------------------------------
create table public.dynamic_links (
  id               uuid primary key default gen_random_uuid(),
  org_id           uuid not null references public.organizations (id) on delete cascade,
  slug             text not null,
  name             text not null,
  destination_url  text not null,
  fallback_url     text,
  status           public.link_status not null default 'active',
  starts_at        timestamptz,
  expires_at       timestamptz,
  created_by       uuid default auth.uid() references auth.users (id) on delete set null,
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now(),
  constraint dynamic_links_slug_key unique (slug),
  constraint dynamic_links_slug_check
    check (slug ~ '^[0-9A-Za-z]{7}$'),
  constraint dynamic_links_name_check
    check (char_length(btrim(name)) between 1 and 120),
  -- Esquema http/https + host no vacío, sin espacios, máx. 2048.
  constraint dynamic_links_destination_url_check
    check (char_length(destination_url) <= 2048
           and destination_url ~* '^https?://[^[:space:]/?#]+([/?#][^[:space:]]*)?$'),
  constraint dynamic_links_fallback_url_check
    check (fallback_url is null
           or (char_length(fallback_url) <= 2048
               and fallback_url ~* '^https?://[^[:space:]/?#]+([/?#][^[:space:]]*)?$')),
  constraint dynamic_links_window_check
    check (starts_at is null or expires_at is null or starts_at < expires_at)
);
comment on table public.dynamic_links is
  'Enlaces dinámicos (QR/NFC). slug inmutable; destino editable con historial. DQR-02.';

-- slug: índice único de la constraint. Listados del dashboard y filtros por estado:
create index dynamic_links_org_created_idx on public.dynamic_links (org_id, created_at desc);
create index dynamic_links_org_status_idx on public.dynamic_links (org_id, status);
-- FK a auth.users (on delete set null).
create index dynamic_links_created_by_idx on public.dynamic_links (created_by);

create table public.link_destination_history (
  id          bigint generated always as identity primary key,
  link_id     uuid not null references public.dynamic_links (id) on delete cascade,
  org_id      uuid not null references public.organizations (id) on delete cascade,
  old_url     text not null,
  new_url     text not null,
  changed_by  uuid references auth.users (id) on delete set null,
  changed_at  timestamptz not null default now()
);
comment on table public.link_destination_history is
  'Historial de destination_url. Solo lo escribe el trigger de dynamic_links. DQR-02.';

create index link_destination_history_link_idx
  on public.link_destination_history (link_id, changed_at desc);
create index link_destination_history_org_idx on public.link_destination_history (org_id);
create index link_destination_history_changed_by_idx on public.link_destination_history (changed_by);

-- -----------------------------------------------------------------------------
-- Triggers
-- -----------------------------------------------------------------------------

-- Columnas inmutables. Aplica a todos los roles (también service_role).
-- SECURITY DEFINER solo para poder consultar auth.users en la excepción de la FK.
create or replace function private.dynamic_links_guard()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if new.id is distinct from old.id
     or new.slug is distinct from old.slug
     or new.org_id is distinct from old.org_id
     or new.created_at is distinct from old.created_at
  then
    raise exception 'dynamic_links: id, slug, org_id y created_at son inmutables'
      using errcode = '42501', hint = 'immutable_column';
  end if;

  if new.created_by is distinct from old.created_by then
    -- Única excepción: FK on delete set null tras borrar el usuario en Auth.
    if not (new.created_by is null
            and not exists (select 1 from auth.users u where u.id = old.created_by))
    then
      raise exception 'dynamic_links: created_by es inmutable'
        using errcode = '42501', hint = 'immutable_column';
    end if;
  end if;

  new.updated_at := now();
  return new;
end;
$$;

create trigger dynamic_links_guard
  before update on public.dynamic_links
  for each row execute function private.dynamic_links_guard();

-- Historial de destino. SECURITY DEFINER: nadie tiene INSERT sobre el historial.
create or replace function private.dynamic_links_log_destination()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  insert into public.link_destination_history (link_id, org_id, old_url, new_url, changed_by)
  values (new.id, new.org_id, old.destination_url, new.destination_url, (select auth.uid()));
  return null;
end;
$$;

create trigger dynamic_links_log_destination
  after update of destination_url on public.dynamic_links
  for each row
  when (old.destination_url is distinct from new.destination_url)
  execute function private.dynamic_links_log_destination();

revoke execute on function private.dynamic_links_guard() from public, anon, authenticated;
revoke execute on function private.dynamic_links_log_destination() from public, anon, authenticated;

-- -----------------------------------------------------------------------------
-- RPC del redirector (solo service_role)
-- -----------------------------------------------------------------------------
create or replace function public.resolve_link(p_slug text)
returns table (
  id               uuid,
  org_id           uuid,
  destination_url  text,
  fallback_url     text,
  status           public.link_status,
  starts_at        timestamptz,
  expires_at       timestamptz,
  org_status       public.org_status
)
language sql
stable
security definer
set search_path = ''
as $$
  select l.id, l.org_id, l.destination_url, l.fallback_url, l.status,
         l.starts_at, l.expires_at, o.status
  from public.dynamic_links l
  join public.organizations o on o.id = l.org_id
  where l.slug = p_slug;
$$;

revoke execute on function public.resolve_link(text) from public, anon, authenticated;
grant execute on function public.resolve_link(text) to service_role;

-- -----------------------------------------------------------------------------
-- Privilegios de tabla (explícitos; RLS filtra filas)
-- -----------------------------------------------------------------------------
revoke all on public.dynamic_links from anon, authenticated;
revoke all on public.link_destination_history from anon, authenticated;

grant select, delete on public.dynamic_links to authenticated;
-- id, slug inmutable fuera del INSERT; created_by/created_at/updated_at no falsificables.
grant insert (org_id, slug, name, destination_url, fallback_url, status, starts_at, expires_at)
  on public.dynamic_links to authenticated;
grant update (name, destination_url, fallback_url, status, starts_at, expires_at)
  on public.dynamic_links to authenticated;

grant select on public.link_destination_history to authenticated;

grant all on public.dynamic_links, public.link_destination_history to service_role;

-- -----------------------------------------------------------------------------
-- RLS
-- -----------------------------------------------------------------------------
alter table public.dynamic_links enable row level security;
alter table public.link_destination_history enable row level security;

-- dynamic_links ---------------------------------------------------------------
create policy dynamic_links_select
  on public.dynamic_links for select
  to authenticated
  using (
    private.is_org_member(org_id)
    or (select private.is_platform_admin())
  );

-- editor+ crea; crear ya archivado exige admin+.
create policy dynamic_links_insert
  on public.dynamic_links for insert
  to authenticated
  with check (
    (select private.is_platform_admin())
    or (
      private.has_org_role(org_id, 'editor')
      and (status <> 'archived' or private.has_org_role(org_id, 'admin'))
    )
  );

-- editor+ edita enlaces no archivados; archivar, desarchivar o tocar un
-- archivado exige admin+.
create policy dynamic_links_update
  on public.dynamic_links for update
  to authenticated
  using (
    (select private.is_platform_admin())
    or (
      private.has_org_role(org_id, 'editor')
      and (status <> 'archived' or private.has_org_role(org_id, 'admin'))
    )
  )
  with check (
    (select private.is_platform_admin())
    or (
      private.has_org_role(org_id, 'editor')
      and (status <> 'archived' or private.has_org_role(org_id, 'admin'))
    )
  );

create policy dynamic_links_delete
  on public.dynamic_links for delete
  to authenticated
  using (
    private.has_org_role(org_id, 'admin')
    or (select private.is_platform_admin())
  );

-- link_destination_history: solo lectura; sin políticas de escritura.
create policy link_destination_history_select
  on public.link_destination_history for select
  to authenticated
  using (
    private.is_org_member(org_id)
    or (select private.is_platform_admin())
  );
