-- =============================================================================
-- DQR-T018 · Enlaces dinámicos: dynamic_links + link_destination_history
-- Módulo DQR-02 · docs/03-modelo-datos.md · docs/04-api.md · docs/06-seguridad.md
--
-- Fase: EXPAND (solo crea objetos nuevos; depende de 20261006011844_tenancy.sql).
--
-- Decisiones:
--   * slug base62 de 7 caracteres, aleatorio y generado por la BD
--     (private.gen_slug, ADR-0006); authenticated no puede fijarlo. Es
--     inmutable para todos los roles (trigger), incluido service_role, y un
--     slug usado nunca se reasigna (private.slug_registry, security H1).
--   * URLs: CHECK http/https sin controles + private.is_safe_url (sin
--     credenciales ni hosts locales/privados) + blocklist
--     private.blocked_domains vía trigger (ADR-0006). La API (T019) sigue
--     siendo la primera línea (normaliza a punycode, self-redirect).
--   * org_id, created_by, id y created_at también son inmutables. Única
--     excepción: created_by pasa a NULL cuando se borra el usuario en Auth
--     (FK on delete set null).
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
-- Slugs (ADR-0006): los genera la BD y nunca se reasignan (security H1)
-- -----------------------------------------------------------------------------
create extension if not exists pgcrypto with schema extensions;

-- Todo slug usado alguna vez. Sin FK: sobrevive al borrado del enlace y de la org.
create table private.slug_registry (
  slug       text primary key,
  org_id     uuid not null,
  created_at timestamptz not null default now()
);
comment on table private.slug_registry is
  'Slugs usados alguna vez; impide reasignarlos (QR/NFC impresos). DQR-T018 H1.';
alter table private.slug_registry enable row level security;
revoke all on private.slug_registry from public, anon, authenticated;
grant all on private.slug_registry to service_role;

-- Slug aleatorio base62 de 7 caracteres (muestreo por rechazo: sin sesgo de
-- módulo). Reintenta si el slug ya fue usado; la PK de slug_registry cierra la
-- carrera residual. SECURITY DEFINER para consultar el registro: es el DEFAULT
-- de dynamic_links.slug y se evalúa con el rol de quien inserta.
create or replace function private.gen_slug()
returns text
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  c_alphabet constant text := '0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz';
  v_slug  text;
  v_bytes bytea;
  v_b     int;
begin
  for attempt in 1..10 loop
    v_slug := '';
    while char_length(v_slug) < 7 loop
      v_bytes := extensions.gen_random_bytes(16);
      for i in 0..15 loop
        v_b := get_byte(v_bytes, i);
        if v_b < 248 then  -- 248 = 62 * 4
          v_slug := v_slug || substr(c_alphabet, (v_b % 62) + 1, 1);
          exit when char_length(v_slug) = 7;
        end if;
      end loop;
    end loop;

    if not exists (select 1 from private.slug_registry r where r.slug = v_slug) then
      return v_slug;
    end if;
  end loop;

  raise exception 'No se pudo generar un slug libre'
    using errcode = '23505', hint = 'slug_exhausted';
end;
$$;

revoke execute on function private.gen_slug() from public, anon;
grant execute on function private.gen_slug() to authenticated, service_role;

-- -----------------------------------------------------------------------------
-- Política de URLs en BD (ADR-0006; espejo de apps/api/app/services/url_policy.py)
-- -----------------------------------------------------------------------------
-- Host normalizado (minúsculas, sin punto final, IPv6 sin corchetes) o NULL si
-- la authority no es válida: vacía, con credenciales ('@') o con puerto inválido.
create or replace function private.url_host(p_url text)
returns text
language plpgsql
immutable
set search_path = ''
as $$
declare
  v_auth text;
  v_host text;
  v_port text;
  v_m    text[];
begin
  v_auth := substring(p_url from '^[A-Za-z][A-Za-z0-9+.-]*://([^/?#]*)');
  if v_auth is null or position('@' in v_auth) > 0 then
    return null;
  end if;

  if left(v_auth, 1) = '[' then
    v_m := regexp_match(v_auth, '^\[([^]]*)\](:([0-9]*))?$');
  else
    v_m := regexp_match(v_auth, '^([^:]*)(:([0-9]*))?$');
  end if;
  if v_m is null then
    return null;
  end if;

  v_host := rtrim(lower(v_m[1]), '.');
  v_port := v_m[3];
  if v_host = '' then
    return null;
  end if;
  if v_port is not null and v_port <> ''
     and (char_length(v_port) > 5 or v_port::int not between 1 and 65535) then
    return null;
  end if;
  return v_host;
end;
$$;

-- true si la URL es http/https, sin credenciales, sin caracteres de control y
-- su host no es local/privado. Hosts numéricos: solo IPv4 decimal canónica
-- pública (rechaza 127.1, 0x7f000001, 2130706433, 0177.0.0.1…). IPv6 literal:
-- solo unicast global (2000::/3) fuera de documentación, 6to4 y Teredo/IETF.
-- Hosts de nombre: ASCII (la API guarda punycode) con al menos un punto.
create or replace function private.is_safe_url(p_url text)
returns boolean
language plpgsql
immutable
set search_path = ''
as $$
declare
  v_host text;
  v_ip   inet;
begin
  if p_url is null
     or char_length(p_url) > 2048
     or p_url !~* '^https?://'
     or p_url ~ '[[:space:][:cntrl:]]'
  then
    return false;
  end if;

  v_host := private.url_host(p_url);
  if v_host is null then
    return false;
  end if;

  -- IPv6 literal
  if position(':' in v_host) > 0 then
    begin
      v_ip := v_host::inet;
    exception when others then
      return false;
    end;
    return family(v_ip) = 6
       and masklen(v_ip) = 128
       and v_ip <<= '2000::/3'::inet
       and not (v_ip <<= '2001::/23'::inet
             or v_ip <<= '2001:db8::/32'::inet
             or v_ip <<= '2002::/16'::inet);
  end if;

  -- Último label numérico (decimal o 0x…): los navegadores lo tratan como IPv4.
  if v_host ~ '(^|\.)([0-9]+|0x[0-9a-f]*)$' then
    if v_host !~ '^(0|[1-9][0-9]{0,2})(\.(0|[1-9][0-9]{0,2})){3}$' then
      return false;
    end if;
    begin
      v_ip := v_host::inet;
    exception when others then
      return false;  -- p. ej. 256.256.256.256
    end;
    return not (v_ip <<= '0.0.0.0/8'::inet
             or v_ip <<= '10.0.0.0/8'::inet
             or v_ip <<= '100.64.0.0/10'::inet
             or v_ip <<= '127.0.0.0/8'::inet
             or v_ip <<= '169.254.0.0/16'::inet
             or v_ip <<= '172.16.0.0/12'::inet
             or v_ip <<= '192.0.0.0/24'::inet
             or v_ip <<= '192.0.2.0/24'::inet
             or v_ip <<= '192.88.99.0/24'::inet
             or v_ip <<= '192.168.0.0/16'::inet
             or v_ip <<= '198.18.0.0/15'::inet
             or v_ip <<= '198.51.100.0/24'::inet
             or v_ip <<= '203.0.113.0/24'::inet
             or v_ip <<= '224.0.0.0/4'::inet
             or v_ip <<= '240.0.0.0/4'::inet);
  end if;

  -- Nombre de host: labels LDH (más '_'), 1..63, al menos dos labels, ≤ 253.
  if char_length(v_host) > 253
     or v_host !~ '^[a-z0-9_]([a-z0-9_-]{0,61}[a-z0-9_])?(\.[a-z0-9_]([a-z0-9_-]{0,61}[a-z0-9_])?)+$'
  then
    return false;
  end if;
  if v_host = 'localhost'
     or v_host like '%.localhost'
     or v_host like '%.local'
     or v_host like '%.internal'
  then
    return false;
  end if;
  return true;
end;
$$;

-- Se evalúan en CHECK con el rol de quien escribe.
revoke execute on function private.url_host(text) from public, anon;
revoke execute on function private.is_safe_url(text) from public, anon;
grant execute on function private.url_host(text) to authenticated, service_role;
grant execute on function private.is_safe_url(text) to authenticated, service_role;

-- Blocklist de dominios (bloquea el dominio y sus subdominios). Solo service_role.
-- Entradas normalizadas: minúsculas, ASCII/punycode, sin puntos extremos.
create table private.blocked_domains (
  domain      text primary key,
  created_at  timestamptz not null default now(),
  constraint blocked_domains_domain_check
    check (char_length(domain) <= 253
           and domain ~ '^[a-z0-9_]([a-z0-9_-]{0,61}[a-z0-9_])?(\.[a-z0-9_]([a-z0-9_-]{0,61}[a-z0-9_])?)*$')
);
comment on table private.blocked_domains is
  'Dominios bloqueados como destino (y sus subdominios). Gestión: service_role. ADR-0006.';
alter table private.blocked_domains enable row level security;
revoke all on private.blocked_domains from public, anon, authenticated;
grant all on private.blocked_domains to service_role;

create or replace function private.url_is_blocked(p_url text)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  with h as (
    select string_to_array(private.url_host(p_url), '.') as labels
  )
  select exists (
    select 1
    from h
    cross join lateral generate_subscripts(h.labels, 1) as i
    join private.blocked_domains d
      on d.domain = array_to_string(h.labels[i:], '.')
  );
$$;

revoke execute on function private.url_is_blocked(text) from public, anon, authenticated;

-- -----------------------------------------------------------------------------
-- Tablas
-- -----------------------------------------------------------------------------
create table public.dynamic_links (
  id               uuid primary key default gen_random_uuid(),
  org_id           uuid not null references public.organizations (id) on delete cascade,
  slug             text not null default private.gen_slug(),
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
  -- Esquema http/https + host no vacío, sin espacios ni controles, máx. 2048.
  constraint dynamic_links_destination_url_check
    check (char_length(destination_url) <= 2048
           and destination_url ~* '^https?://[^[:space:]/?#]+([/?#][^[:space:]]*)?$'
           and destination_url !~ '[[:cntrl:]]'),
  constraint dynamic_links_fallback_url_check
    check (fallback_url is null
           or (char_length(fallback_url) <= 2048
               and fallback_url ~* '^https?://[^[:space:]/?#]+([/?#][^[:space:]]*)?$'
               and fallback_url !~ '[[:cntrl:]]')),
  -- Sin credenciales ni hosts locales/privados (ADR-0006).
  constraint dynamic_links_destination_url_safe_check
    check (private.is_safe_url(destination_url)),
  constraint dynamic_links_fallback_url_safe_check
    check (fallback_url is null or private.is_safe_url(fallback_url)),
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

-- Registro de slugs: un slug usado nunca se reasigna, en ninguna org ni rol (H1).
create or replace function private.dynamic_links_register_slug()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  insert into private.slug_registry (slug, org_id) values (new.slug, new.org_id);
  return new;
exception when unique_violation then
  raise exception 'dynamic_links: el slug ya fue usado y no se reasigna'
    using errcode = '23505', hint = 'slug_taken';
end;
$$;

create trigger dynamic_links_register_slug
  before insert on public.dynamic_links
  for each row execute function private.dynamic_links_register_slug();

-- Blocklist de dominios para destino y fallback (ADR-0006).
create or replace function private.dynamic_links_check_blocklist()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if (tg_op = 'INSERT' or new.destination_url is distinct from old.destination_url)
     and private.url_is_blocked(new.destination_url)
  then
    raise exception 'dynamic_links: el dominio de destino no está permitido'
      using errcode = '23514', hint = 'url_blocked_domain';
  end if;

  if new.fallback_url is not null
     and (tg_op = 'INSERT' or new.fallback_url is distinct from old.fallback_url)
     and private.url_is_blocked(new.fallback_url)
  then
    raise exception 'dynamic_links: el dominio del fallback no está permitido'
      using errcode = '23514', hint = 'url_blocked_domain';
  end if;

  return new;
end;
$$;

create trigger dynamic_links_check_blocklist
  before insert or update of destination_url, fallback_url on public.dynamic_links
  for each row execute function private.dynamic_links_check_blocklist();

revoke execute on function private.dynamic_links_register_slug() from public, anon, authenticated;
revoke execute on function private.dynamic_links_check_blocklist() from public, anon, authenticated;
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
-- Sin id ni slug (lo genera la BD, ADR-0006); created_by/created_at/updated_at
-- no falsificables. service_role sí puede fijar el slug (seed).
grant insert (org_id, name, destination_url, fallback_url, status, starts_at, expires_at)
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
