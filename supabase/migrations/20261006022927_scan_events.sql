-- =============================================================================
-- DQR-T022 · Eventos de escaneo: scan_events + public.record_scan()
-- Módulos DQR-03 (redirector) y DQR-06 (analytics) · docs/03-modelo-datos.md ·
-- docs/06-seguridad.md (eventos y privacidad) · ADR-0004 (canal por parámetro)
--
-- Fase: EXPAND (solo añade objetos; depende de 20261006013540_links.sql).
--   El único cambio sobre un objeto existente es un UNIQUE (id, org_id) en
--   dynamic_links, compatible hacia atrás (id ya es PK, así que nunca falla).
--
-- Decisiones:
--   * Coherencia de org: FK compuesta (link_id, org_id) → dynamic_links (id, org_id)
--     on delete cascade. Un evento no puede llevar un org_id distinto al de su
--     enlace, para ningún rol (tampoco service_role). dynamic_links.org_id es
--     inmutable (trigger dynamic_links_guard), así que la FK nunca se rompe por
--     un UPDATE. No hay FK directa a organizations: la implica la compuesta
--     (dynamic_links.org_id → organizations on delete cascade) y nos ahorramos
--     una comprobación por inserción.
--   * Escritura: solo service_role. El redirector usa public.record_scan()
--     (SECURITY DEFINER, EXECUTE solo service_role), que valida el canal y el
--     ip_hash y sanea/recorta los campos que vienen de cabeceras del cliente.
--     authenticated solo lee (RLS: miembros de la org, viewer+, y platform
--     admin). anon no tiene ningún privilegio. Nadie más actualiza ni borra.
--   * Privacidad (docs/06): nunca se guarda la IP. ip_hash solo admite hex en
--     minúsculas de 32..128 caracteres (CHECK), así que una IPv4/IPv6 literal
--     se rechaza. Sin cookies ni identificadores del cliente.
--   * tag_id: uuid sin FK. nfc_tags llega en DQR-T034, que añadirá la FK
--     (link_id/org_id coherentes) y su índice. Solo tiene sentido con canal
--     nfc (ADR-0004: ?c=n&t={tag}).
--   * Índices (tabla append-only de alto volumen):
--       - (link_id, occurred_at desc): estadísticas por enlace y borrado en
--         cascada del enlace (cubre la FK, columna inicial link_id).
--       - (org_id, occurred_at desc): estadísticas por organización y RLS.
--       - BRIN (occurred_at): los eventos se insertan en orden temporal
--         (occurred_at = now()), así que la correlación física es ~1. Sirve a
--         los barridos globales por rango de fechas (rollups diarios de
--         DQR-T041 y futura retención/archivado) con un índice de pocos KB y
--         coste de escritura casi nulo, en lugar de un btree (occurred_at) que
--         pesaría como la propia columna. No se añaden más btree para no
--         penalizar el insert del redirector.
--   * Particionado: no ahora (volumen inicial bajo). Ver la nota del PR: el
--     camino previsto es particionar por rango mensual de occurred_at cuando
--     la tabla se acerque a ~100M filas o haga falta retención.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- Tipos
-- -----------------------------------------------------------------------------
create type public.scan_channel as enum ('qr', 'nfc', 'direct');

-- -----------------------------------------------------------------------------
-- dynamic_links: clave (id, org_id) para la FK compuesta (expand compatible)
-- -----------------------------------------------------------------------------
alter table public.dynamic_links
  add constraint dynamic_links_id_org_key unique (id, org_id);

-- -----------------------------------------------------------------------------
-- Tabla
-- -----------------------------------------------------------------------------
create table public.scan_events (
  id           bigint generated always as identity primary key,
  link_id      uuid not null,
  org_id       uuid not null,
  channel      public.scan_channel not null,
  tag_id       uuid,
  occurred_at  timestamptz not null default now(),
  country      char(2),
  device       text,
  os           text,
  browser      text,
  referer      text,
  ip_hash      text,
  is_bot       boolean not null default false,
  constraint scan_events_link_org_fkey
    foreign key (link_id, org_id)
    references public.dynamic_links (id, org_id)
    on delete cascade,
  constraint scan_events_tag_channel_check
    check (tag_id is null or channel = 'nfc'),
  constraint scan_events_country_check
    check (country is null or country ~ '^[A-Z]{2}$'),
  constraint scan_events_device_check
    check (device is null or char_length(device) between 1 and 64),
  constraint scan_events_os_check
    check (os is null or char_length(os) between 1 and 64),
  constraint scan_events_browser_check
    check (browser is null or char_length(browser) between 1 and 64),
  constraint scan_events_referer_check
    check (referer is null or char_length(referer) between 1 and 512),
  -- Hash hex en minúsculas (p. ej. SHA-256 = 64). Nunca la IP en claro.
  constraint scan_events_ip_hash_check
    check (ip_hash is null or ip_hash ~ '^[0-9a-f]{32,128}$')
);
comment on table public.scan_events is
  'Escaneos (append-only). Escribe solo service_role vía record_scan(); leen los miembros de la org. DQR-03/06.';
comment on column public.scan_events.org_id is
  'Coherente con el enlace por la FK compuesta (link_id, org_id) → dynamic_links (id, org_id).';
comment on column public.scan_events.tag_id is
  'Etiqueta NFC (ADR-0004, ?t=). Sin FK hasta DQR-T034 (nfc_tags). Solo con channel = nfc.';
comment on column public.scan_events.country is
  'ISO 3166-1 alfa-2 en mayúsculas (cabecera de la plataforma).';
comment on column public.scan_events.ip_hash is
  'Hash de la IP con sal rotativa (docs/06). Nunca la IP. Hex en minúsculas, 32..128.';
comment on column public.scan_events.is_bot is
  'Marcado por el enriquecimiento (DQR-T040); los bots se excluyen de las métricas.';

create index scan_events_link_occurred_idx on public.scan_events (link_id, occurred_at desc);
create index scan_events_org_occurred_idx on public.scan_events (org_id, occurred_at desc);
create index scan_events_occurred_brin_idx on public.scan_events using brin (occurred_at);

-- -----------------------------------------------------------------------------
-- Saneado de campos que vienen de cabeceras del cliente
-- -----------------------------------------------------------------------------
-- Quita caracteres de control, recorta espacios, corta a p_max y devuelve NULL
-- si queda vacío.
create or replace function private.scan_clip(p_value text, p_max int)
returns text
language sql
immutable
set search_path = ''
as $$
  select nullif(
    left(btrim(regexp_replace(p_value, '[[:cntrl:]]', '', 'g')), p_max),
    ''
  );
$$;

revoke execute on function private.scan_clip(text, int) from public, anon, authenticated;
grant execute on function private.scan_clip(text, int) to service_role;

-- -----------------------------------------------------------------------------
-- RPC del redirector (solo service_role)
-- -----------------------------------------------------------------------------
-- Errores:
--   22023 hint invalid_channel  · canal distinto de qr/nfc/direct
--   22023 hint invalid_ip_hash  · ip_hash que no es hex de 32..128 (p. ej. una IP)
--   23503                       · el enlace no existe o no pertenece a p_org_id
-- Saneado (no falla): country inválido → NULL; device/os/browser ≤ 64,
-- referer ≤ 512, sin caracteres de control; tag_id se descarta si el canal
-- no es nfc.
create or replace function public.record_scan(
  p_link_id  uuid,
  p_org_id   uuid,
  p_channel  text,
  p_tag_id   uuid    default null,
  p_country  text    default null,
  p_device   text    default null,
  p_os       text    default null,
  p_browser  text    default null,
  p_referer  text    default null,
  p_ip_hash  text    default null,
  p_is_bot   boolean default false
)
returns bigint
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_channel public.scan_channel;
  v_country text;
  v_ip_hash text;
  v_id      bigint;
begin
  if p_channel is null or p_channel not in ('qr', 'nfc', 'direct') then
    raise exception 'record_scan: canal no válido'
      using errcode = '22023', hint = 'invalid_channel';
  end if;
  v_channel := p_channel::public.scan_channel;

  v_ip_hash := lower(btrim(p_ip_hash));
  if v_ip_hash = '' then
    v_ip_hash := null;
  end if;
  if v_ip_hash is not null and v_ip_hash !~ '^[0-9a-f]{32,128}$' then
    raise exception 'record_scan: ip_hash no válido (nunca la IP)'
      using errcode = '22023', hint = 'invalid_ip_hash';
  end if;

  v_country := upper(btrim(p_country));
  if v_country !~ '^[A-Z]{2}$' then
    v_country := null;
  end if;

  insert into public.scan_events
    (link_id, org_id, channel, tag_id, country, device, os, browser, referer, ip_hash, is_bot)
  values (
    p_link_id,
    p_org_id,
    v_channel,
    case when v_channel = 'nfc' then p_tag_id end,
    v_country,
    private.scan_clip(p_device, 64),
    private.scan_clip(p_os, 64),
    private.scan_clip(p_browser, 64),
    private.scan_clip(p_referer, 512),
    v_ip_hash,
    coalesce(p_is_bot, false)
  )
  returning id into v_id;

  return v_id;
end;
$$;

revoke execute on function
  public.record_scan(uuid, uuid, text, uuid, text, text, text, text, text, text, boolean)
  from public, anon, authenticated;
grant execute on function
  public.record_scan(uuid, uuid, text, uuid, text, text, text, text, text, text, boolean)
  to service_role;

-- -----------------------------------------------------------------------------
-- Privilegios de tabla (explícitos; RLS filtra filas)
-- -----------------------------------------------------------------------------
revoke all on public.scan_events from anon, authenticated;
revoke all on sequence public.scan_events_id_seq from anon, authenticated;

grant select on public.scan_events to authenticated;
grant select, insert, update, delete on public.scan_events to service_role;
grant usage, select on sequence public.scan_events_id_seq to service_role;

-- -----------------------------------------------------------------------------
-- RLS: solo lectura para miembros (viewer+) y platform admin; sin políticas
-- de escritura (service_role no está sujeto a RLS).
-- -----------------------------------------------------------------------------
alter table public.scan_events enable row level security;

create policy scan_events_select
  on public.scan_events for select
  to authenticated
  using (
    private.is_org_member(org_id)
    or (select private.is_platform_admin())
  );
