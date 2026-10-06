-- =============================================================================
-- DQR-T034 · Etiquetas NFC: nfc_tags + FK de scan_events.tag_id + record_scan
-- Módulo DQR-05 · docs/03-modelo-datos.md · ADR-0004 (?c=n&t={tag}) ·
-- revisión de seguridad de DQR-T022, hallazgo H1 (tag_id sin validar)
--
-- Fase: EXPAND (depende de 20261006022927_scan_events.sql y del endurecimiento
-- 20261006024532_scan_clip_hardening.sql).
--   * Crea nfc_tags (objeto nuevo).
--   * scan_events: limpia los tag_id huérfanos (→ NULL) y añade la FK
--     compuesta (tag_id, link_id) → nfc_tags (id, link_id), NOT VALID +
--     VALIDATE. Hoy no existe ninguna etiqueta, así que todo tag_id previo es
--     huérfano por definición (lo controla quien escanea, H1).
--   * record_scan: misma firma y mismos grants. Si p_tag_id no es una etiqueta
--     del enlace, guarda tag_id NULL en vez de fallar (el escaneo nunca se
--     pierde).
--   * Orden (revisión T034 H1): 1) nfc_tags + RLS; 2) record_scan nuevo, antes
--     de tocar la FK, para que ningún INSERT concurrente guarde un tag ajeno;
--     3) LOCK de scan_events; 4) limpieza, FK NOT VALID, VALIDATE e índice.
--     A escala (millones de eventos) convendría VALIDATE y CREATE INDEX
--     CONCURRENTLY en una migración aparte; hoy la tabla es pequeña.
--
-- Decisiones:
--   * Coherencia de org: FK compuesta (link_id, org_id) → dynamic_links
--     (id, org_id) on delete cascade. Una etiqueta no puede llevar un org_id
--     distinto al de su enlace, para ningún rol (tampoco service_role).
--   * unique (id, link_id): destino de la FK de scan_events. Así un evento
--     solo puede apuntar a una etiqueta de su propio enlace (y, por la FK
--     (link_id, org_id) de ambos lados, de su propia org).
--   * uid (UID físico del chip): opcional. Se normaliza en BD (trigger) a hex
--     en MAYÚSCULAS sin separadores (acepta "04:a2:5b…", "04-A2-…", espacios).
--     CHECK: 4, 7 o 10 bytes (8, 14 o 20 hex; ISO/IEC 14443-3 single/double/
--     triple size). Único por org cuando no es NULL (unique (org_id, uid); los
--     NULL no colisionan).
--   * label 1..80 y location ≤ 120 (opcional), sin caracteres de control ni
--     de formato Unicode (los mismos rangos que private.scan_clip: U+00AD,
--     U+200B..U+200F, U+2028..U+202E, U+2060..U+206F, U+FEFF; revisión T034
--     H2). Se rechazan con CHECK (23514) en vez de quitarlos: scan_clip solo
--     lo ejecuta service_role y el trigger corre con el rol de quien escribe.
--     location vacía/solo espacios → NULL (trigger).
--   * id, link_id, org_id y created_at son inmutables para todos los roles
--     (trigger), además de no tener grant de UPDATE para authenticated.
--   * Permisos (matriz de docs/03): viewer lee; editor+ crea y edita; admin+
--     borra. Platform admin puede todo.
--   * scan_events → nfc_tags on delete set null (tag_id): borrar una etiqueta
--     conserva sus escaneos (pasan a tag_id NULL, siguen con canal nfc).
-- =============================================================================

-- -----------------------------------------------------------------------------
-- Tabla
-- -----------------------------------------------------------------------------
create table public.nfc_tags (
  id          uuid primary key default gen_random_uuid(),
  link_id     uuid not null,
  org_id      uuid not null,
  label       text not null,
  location    text,
  uid         text,
  created_at  timestamptz not null default now(),
  constraint nfc_tags_link_org_fkey
    foreign key (link_id, org_id)
    references public.dynamic_links (id, org_id)
    on delete cascade,
  constraint nfc_tags_id_link_key unique (id, link_id),
  constraint nfc_tags_org_uid_key unique (org_id, uid),
  constraint nfc_tags_label_check
    check (char_length(btrim(label)) between 1 and 80
           and label !~ '[[:cntrl:]]'
           and label !~ E'[\u00AD\u200B-\u200F\u2028-\u202E\u2060-\u206F\uFEFF]'),
  constraint nfc_tags_location_check
    check (location is null
           or (char_length(btrim(location)) between 1 and 120
               and location !~ '[[:cntrl:]]'
               and location !~ E'[\u00AD\u200B-\u200F\u2028-\u202E\u2060-\u206F\uFEFF]')),
  constraint nfc_tags_uid_check
    check (uid is null or uid ~ '^([0-9A-F]{8}|[0-9A-F]{14}|[0-9A-F]{20})$')
);
comment on table public.nfc_tags is
  'Etiquetas NFC de un enlace (ubicación y UID del chip). URL NDEF …/r/{slug}?c=n&t={id}. DQR-05.';
comment on column public.nfc_tags.org_id is
  'Coherente con el enlace por la FK compuesta (link_id, org_id) → dynamic_links (id, org_id).';
comment on column public.nfc_tags.uid is
  'UID físico del chip: hex en mayúsculas sin separadores (4, 7 o 10 bytes). Único por org si no es NULL.';

-- FK (link_id, org_id) y listados por enlace. Por org: lo cubre nfc_tags_org_uid_key.
create index nfc_tags_link_idx on public.nfc_tags (link_id, created_at desc);

-- -----------------------------------------------------------------------------
-- Trigger: normalización y columnas inmutables (todos los roles)
-- -----------------------------------------------------------------------------
create or replace function private.nfc_tags_normalize()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if tg_op = 'UPDATE'
     and (new.id is distinct from old.id
          or new.link_id is distinct from old.link_id
          or new.org_id is distinct from old.org_id
          or new.created_at is distinct from old.created_at)
  then
    raise exception 'nfc_tags: id, link_id, org_id y created_at son inmutables'
      using errcode = '42501', hint = 'immutable_column';
  end if;

  new.label := btrim(new.label);
  new.location := nullif(btrim(new.location), '');
  -- Quita separadores habituales (":", "-", espacios) y pasa a mayúsculas.
  -- Lo que no sea hex queda y lo rechaza el CHECK.
  new.uid := nullif(upper(regexp_replace(new.uid, '[:[:space:]-]', '', 'g')), '');
  return new;
end;
$$;

revoke execute on function private.nfc_tags_normalize() from public, anon, authenticated;

create trigger nfc_tags_normalize
  before insert or update on public.nfc_tags
  for each row execute function private.nfc_tags_normalize();

-- -----------------------------------------------------------------------------
-- Privilegios (explícitos; RLS filtra filas)
-- -----------------------------------------------------------------------------
revoke all on public.nfc_tags from anon, authenticated;

grant select, delete on public.nfc_tags to authenticated;
-- Sin id ni created_at (los pone la BD); link_id y org_id no se cambian.
grant insert (link_id, org_id, label, location, uid) on public.nfc_tags to authenticated;
grant update (label, location, uid) on public.nfc_tags to authenticated;

grant select, insert, update, delete on public.nfc_tags to service_role;

-- -----------------------------------------------------------------------------
-- RLS
-- -----------------------------------------------------------------------------
alter table public.nfc_tags enable row level security;

create policy nfc_tags_select
  on public.nfc_tags for select
  to authenticated
  using (
    private.is_org_member(org_id)
    or (select private.is_platform_admin())
  );

create policy nfc_tags_insert
  on public.nfc_tags for insert
  to authenticated
  with check (
    private.has_org_role(org_id, 'editor')
    or (select private.is_platform_admin())
  );

create policy nfc_tags_update
  on public.nfc_tags for update
  to authenticated
  using (
    private.has_org_role(org_id, 'editor')
    or (select private.is_platform_admin())
  )
  with check (
    private.has_org_role(org_id, 'editor')
    or (select private.is_platform_admin())
  );

create policy nfc_tags_delete
  on public.nfc_tags for delete
  to authenticated
  using (
    private.has_org_role(org_id, 'admin')
    or (select private.is_platform_admin())
  );

-- -----------------------------------------------------------------------------
-- record_scan: tag ajeno o inexistente → tag_id NULL (misma firma y grants)
-- -----------------------------------------------------------------------------
-- Errores:
--   22023 hint invalid_channel  · canal distinto de qr/nfc/direct
--   22023 hint invalid_ip_hash  · ip_hash que no es hex de 32..128 (p. ej. una IP)
--   23503                       · el enlace no existe o no pertenece a p_org_id
-- Saneado (no falla): country inválido → NULL; device/os/browser ≤ 64,
-- referer ≤ 512, sin caracteres de control; tag_id se descarta si el canal
-- no es nfc o si no es una etiqueta de p_link_id.
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
  v_tag_id  uuid;
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

  -- Solo una etiqueta del propio enlace. FOR KEY SHARE (el mismo bloqueo que
  -- tomaría la FK) evita que un DELETE concurrente de la etiqueta haga fallar
  -- el INSERT: si se borra antes, no se encuentra y queda NULL; si se borra
  -- después, la FK la pone a NULL.
  if v_channel = 'nfc' and p_tag_id is not null then
    select t.id into v_tag_id
    from public.nfc_tags t
    where t.id = p_tag_id and t.link_id = p_link_id
    for key share;
  end if;

  insert into public.scan_events
    (link_id, org_id, channel, tag_id, country, device, os, browser, referer, ip_hash, is_bot)
  values (
    p_link_id,
    p_org_id,
    v_channel,
    v_tag_id,
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

alter function
  public.record_scan(uuid, uuid, text, uuid, text, text, text, text, text, text, boolean)
  owner to postgres;
revoke execute on function
  public.record_scan(uuid, uuid, text, uuid, text, text, text, text, text, text, boolean)
  from public, anon, authenticated;
grant execute on function
  public.record_scan(uuid, uuid, text, uuid, text, text, text, text, text, text, boolean)
  to service_role;

-- -----------------------------------------------------------------------------
-- scan_events.tag_id → nfc_tags (H1 de DQR-T022)
-- -----------------------------------------------------------------------------
-- Todo en un único bloque DO: el CLI de Supabase no envuelve la migración en
-- una transacción (LOCK TABLE suelto falla con 25P01), y así el bloqueo dura
-- desde la limpieza hasta el índice, sea cual sea el modo de aplicación.
do $$
begin
  -- 0) Bloqueo: hasta el commit nadie escribe en scan_events (los INSERT de
  --    record_scan esperan y luego se validan contra la FK nueva con la
  --    función nueva, que ya no guarda tags ajenos). SHARE ROW EXCLUSIVE es el
  --    mismo modo que toma ADD FOREIGN KEY; las lecturas siguen permitidas.
  lock table public.scan_events in share row exclusive mode;

  -- 1) Limpieza: tag_id que no es una etiqueta del mismo enlace → NULL.
  update public.scan_events e
  set tag_id = null
  where e.tag_id is not null
    and not exists (
      select 1 from public.nfc_tags t
      where t.id = e.tag_id and t.link_id = e.link_id
    );

  -- 2) FK compuesta: el evento solo apunta a etiquetas de su enlace. Borrar la
  --    etiqueta deja tag_id en NULL (el escaneo se conserva).
  alter table public.scan_events
    add constraint scan_events_tag_link_fkey
      foreign key (tag_id, link_id)
      references public.nfc_tags (id, link_id)
      on delete set null (tag_id)
      not valid;

  alter table public.scan_events validate constraint scan_events_tag_link_fkey;

  -- 3) Cubre la FK (set null al borrar una etiqueta) y las estadísticas por
  --    etiqueta. Parcial: la mayoría de eventos no llevan etiqueta.
  create index scan_events_tag_occurred_idx
    on public.scan_events (tag_id, occurred_at desc)
    where tag_id is not null;
end
$$;

comment on column public.scan_events.tag_id is
  'Etiqueta NFC (ADR-0004, ?t=). FK (tag_id, link_id) → nfc_tags (id, link_id) on delete set null. Solo con channel = nfc.';
