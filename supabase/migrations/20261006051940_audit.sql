-- =============================================================================
-- DQR-T052 · audit_log: registro append-only de cambios de enlaces, miembros y
-- organizaciones.
-- Módulo DQR-08 · docs/03-modelo-datos.md (audit_log) · docs/06-seguridad.md (H6)
--
-- Fase: EXPAND (solo crea objetos nuevos; depende de tenancy, links,
-- nfc_tags y qr_designs).
--
-- Decisiones:
--   * Una fila por cambio de fila (triggers AFTER ROW). Función genérica
--     private.audit_row() parametrizada con argumentos del trigger; la llaman
--     dynamic_links, memberships, nfc_tags, qr_designs y organizations (esta
--     última solo para cambios de name, plan y status, como pide la tarea).
--   * actor = auth.uid() (DEFAULT de la columna): el usuario del JWT; NULL
--     cuando escribe service_role, un job o postgres (no hay `sub`).
--   * action = '<entidad>.<verbo>':
--       INSERT → created · DELETE → deleted
--       UPDATE → el primer verbo específico cuya columna cambió
--                (link.destination_changed, link.status_changed,
--                 member.role_changed, nfc_tag.renamed, nfc_tag.moved,
--                 nfc_tag.uid_changed, org.status_changed, org.plan_changed,
--                 org.renamed); si ninguna, <entidad>.updated.
--     entity = 'link' | 'member' | 'nfc_tag' | 'qr_design' | 'org';
--     entity_id = id del enlace / etiqueta / org, user_id de la membresía (la
--     org ya está en org_id) o link_id del diseño (es su PK).
--   * diff = { columna: { "old": …, "new": … } } solo con las columnas que
--     cambiaron. INSERT: old = null; DELETE: new = null (así el borrado de un
--     enlace conserva su último destino, H6 de T018). Se excluyen siempre la
--     columna id, org_id, created_at y updated_at (ruido o ya en la fila de
--     auditoría). Un UPDATE sin cambios reales no genera fila.
--   * org_id SIN FK a organizations: la auditoría sobrevive al borrado de la
--     org (y el borrado en cascada de sus enlaces/miembros queda registrado; con
--     FK esos INSERT fallarían). actor sin FK a auth.users por la misma razón.
--   * Append-only para todos: authenticated y service_role solo tienen SELECT y
--     un trigger rechaza UPDATE/DELETE/TRUNCATE también a postgres. Una futura
--     purga por retención necesitará su propia migración (y revisión).
--   * RLS: leen admin+ de la org y platform admin. Sin políticas de escritura;
--     solo escribe private.audit_row() (SECURITY DEFINER). La política es por
--     conjunto (private.my_admin_org_ids(), evaluada una vez por consulta) y no
--     fila a fila: con has_org_role por fila un usuario sin org forzaba un
--     recorrido completo de la tabla vía PostgREST (sec-T052 H1).
-- =============================================================================

-- -----------------------------------------------------------------------------
-- Tabla
-- -----------------------------------------------------------------------------
create table public.audit_log (
  id         bigint generated always as identity primary key,
  org_id     uuid not null,
  actor      uuid default auth.uid(),
  action     text not null,
  entity     text not null,
  entity_id  text not null,
  diff       jsonb not null default '{}'::jsonb,
  at         timestamptz not null default now(),
  constraint audit_log_action_check
    check (action ~ '^[a-z][a-z0-9_]*\.[a-z][a-z0-9_]*$'),
  constraint audit_log_entity_check
    check (entity ~ '^[a-z][a-z0-9_]*$'),
  constraint audit_log_diff_check
    check (jsonb_typeof(diff) = 'object')
);
comment on table public.audit_log is
  'Auditoría append-only de enlaces, miembros y organizaciones. La escriben triggers. DQR-T052.';
comment on column public.audit_log.actor is
  'auth.uid() de quien hizo el cambio; NULL si fue service_role, un job o postgres.';
comment on column public.audit_log.diff is
  '{columna: {old, new}} solo con columnas cambiadas (sin id, org_id, created_at, updated_at).';

-- Listado por org (dashboard / RLS) e historial de una entidad.
create index audit_log_org_at_idx on public.audit_log (org_id, at desc);
create index audit_log_entity_idx on public.audit_log (entity, entity_id);

-- -----------------------------------------------------------------------------
-- Función genérica de auditoría
-- -----------------------------------------------------------------------------
-- Argumentos del trigger:
--   0 entidad ('link', 'member', 'org')
--   1 columna id de la entidad
--   2 columna org_id
--   3 columnas auditadas: '*' = todas, o lista separada por comas
--   4 columnas excluidas además de id, org_id, created_at y updated_at ('' = ninguna)
--   5 verbos de UPDATE por prioridad: 'columna:verbo,columna:verbo' ('' = ninguno)
-- Los argumentos los fija la migración (no hay entrada de usuario). SECURITY
-- DEFINER porque nadie tiene INSERT sobre audit_log.
create or replace function private.audit_row()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_entity  text := tg_argv[0];
  v_id_col  text := tg_argv[1];
  v_org_col text := tg_argv[2];
  v_include text[];
  v_exclude text[];
  v_old     jsonb := '{}'::jsonb;
  v_new     jsonb := '{}'::jsonb;
  v_row     jsonb;
  v_diff    jsonb;
  v_verb    text;
  v_rule    text;
begin
  if tg_nargs <> 6 or tg_level <> 'ROW' or tg_when <> 'AFTER' then
    raise exception 'private.audit_row(): uso inválido en %.%', tg_table_schema, tg_table_name;
  end if;

  v_include := case when tg_argv[3] = '*' then null else string_to_array(tg_argv[3], ',') end;
  v_exclude := array[v_id_col, v_org_col, 'created_at', 'updated_at']
               || coalesce(string_to_array(nullif(tg_argv[4], ''), ','), '{}'::text[]);

  if tg_op <> 'INSERT' then
    v_old := to_jsonb(old);
  end if;
  if tg_op <> 'DELETE' then
    v_new := to_jsonb(new);
  end if;
  v_row := case when tg_op = 'DELETE' then v_old else v_new end;

  select coalesce(
           jsonb_object_agg(
             k.key,
             jsonb_build_object('old', coalesce(v_old -> k.key, 'null'::jsonb),
                                'new', coalesce(v_new -> k.key, 'null'::jsonb))),
           '{}'::jsonb)
    into v_diff
    from (select jsonb_object_keys(v_old) union select jsonb_object_keys(v_new)) as k(key)
   where (v_include is null or k.key = any (v_include))
     and k.key <> all (v_exclude)
     and coalesce(v_old -> k.key, 'null'::jsonb) is distinct from coalesce(v_new -> k.key, 'null'::jsonb);

  if tg_op = 'INSERT' then
    v_verb := 'created';
  elsif tg_op = 'DELETE' then
    v_verb := 'deleted';
  else
    if v_diff = '{}'::jsonb then
      return null;  -- UPDATE sin cambios en columnas auditadas
    end if;
    v_verb := 'updated';
    foreach v_rule in array coalesce(string_to_array(nullif(tg_argv[5], ''), ','), '{}'::text[]) loop
      if v_diff ? split_part(v_rule, ':', 1) then
        v_verb := split_part(v_rule, ':', 2);
        exit;
      end if;
    end loop;
  end if;

  -- actor: DEFAULT auth.uid().
  insert into public.audit_log (org_id, action, entity, entity_id, diff)
  values ((v_row ->> v_org_col)::uuid,
          v_entity || '.' || v_verb,
          v_entity,
          v_row ->> v_id_col,
          v_diff);

  return null;
end;
$$;

comment on function private.audit_row() is
  'Trigger AFTER ROW genérico que escribe public.audit_log. DQR-T052.';

-- Append-only: rechaza UPDATE, DELETE y TRUNCATE para cualquier rol (incluido
-- postgres/service_role, que no pasan por RLS ni por los GRANT).
create or replace function private.audit_log_append_only()
returns trigger
language plpgsql
security invoker
set search_path = ''
as $$
begin
  raise exception 'audit_log es append-only: % no permitido', tg_op
    using errcode = '42501', hint = 'audit_append_only';
end;
$$;

revoke execute on function private.audit_row() from public, anon, authenticated;
revoke execute on function private.audit_log_append_only() from public, anon, authenticated;

create trigger audit_log_append_only
  before update or delete on public.audit_log
  for each row execute function private.audit_log_append_only();

create trigger audit_log_no_truncate
  before truncate on public.audit_log
  for each statement execute function private.audit_log_append_only();

-- -----------------------------------------------------------------------------
-- Triggers de auditoría
-- -----------------------------------------------------------------------------
create trigger dynamic_links_audit
  after insert or update or delete on public.dynamic_links
  for each row execute function private.audit_row(
    'link', 'id', 'org_id', '*', '',
    'destination_url:destination_changed,status:status_changed');

create trigger memberships_audit
  after insert or update or delete on public.memberships
  for each row execute function private.audit_row(
    'member', 'user_id', 'org_id', '*', '',
    'role:role_changed');

-- Solo cambios de name, plan y status (no slug, limits, alta ni borrado).
create trigger organizations_audit
  after update of name, plan, status on public.organizations
  for each row execute function private.audit_row(
    'org', 'id', 'id', 'name,plan,status', '',
    'status:status_changed,plan:plan_changed,name:renamed');

-- nfc_tags: entity_id = id; link_id (inmutable) aparece en created/deleted.
create trigger nfc_tags_audit
  after insert or update or delete on public.nfc_tags
  for each row execute function private.audit_row(
    'nfc_tag', 'id', 'org_id', '*', '',
    'label:renamed,location:moved,uid:uid_changed');

-- qr_designs: la PK es link_id (no hay columna id).
create trigger qr_designs_audit
  after insert or update or delete on public.qr_designs
  for each row execute function private.audit_row(
    'qr_design', 'link_id', 'org_id', '*', '', '');

-- -----------------------------------------------------------------------------
-- Privilegios (explícitos; RLS filtra filas). Nadie escribe salvo los triggers.
-- -----------------------------------------------------------------------------
revoke all on public.audit_log from public, anon, authenticated, service_role;
grant select on public.audit_log to authenticated, service_role;

-- -----------------------------------------------------------------------------
-- RLS
-- -----------------------------------------------------------------------------
alter table public.audit_log enable row level security;

-- Orgs donde el usuario es admin+ (org_role: viewer < editor < admin < owner).
-- Por conjunto (sec-T052 H1): se evalúa una vez por consulta (hashed SubPlan).
create or replace function private.my_admin_org_ids()
returns setof uuid
language sql stable security definer set search_path = '' as $$
  select m.org_id from public.memberships m
  where m.user_id = (select auth.uid()) and m.role in ('admin', 'owner')
$$;
comment on function private.my_admin_org_ids() is
  'org_id donde auth.uid() es admin u owner. Para RLS por conjunto. DQR-T052 (sec H1).';
alter function private.my_admin_org_ids() owner to postgres;
revoke execute on function private.my_admin_org_ids() from public, anon;
grant execute on function private.my_admin_org_ids() to authenticated;

-- admin+ de la org y platform admin. Sin políticas de INSERT/UPDATE/DELETE.
create policy audit_log_select
  on public.audit_log for select
  to authenticated
  using (
    org_id in (select private.my_admin_org_ids())
    or (select private.is_platform_admin())
  );
