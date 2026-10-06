-- DQR-T052 · Tests de audit_log (pgTAP).
-- Ejecutar: supabase test db. Todo corre dentro de BEGIN … ROLLBACK: no deja datos.
begin;

create extension if not exists pgtap with schema extensions;

select plan(99);

-- -----------------------------------------------------------------------------
-- Fixtures (como postgres, sin JWT → actor NULL)
-- -----------------------------------------------------------------------------
-- Org A: a1 owner · a3 admin · e1 editor · a2 viewer
-- Org B: b1 owner · pa platform admin · cc sin org
insert into auth.users (id, email, aud, role) values
  ('00000000-0000-0000-0000-0000000000a1', 'a1@test.local', 'authenticated', 'authenticated'),
  ('00000000-0000-0000-0000-0000000000a2', 'a2@test.local', 'authenticated', 'authenticated'),
  ('00000000-0000-0000-0000-0000000000a3', 'a3@test.local', 'authenticated', 'authenticated'),
  ('00000000-0000-0000-0000-0000000000e1', 'e1@test.local', 'authenticated', 'authenticated'),
  ('00000000-0000-0000-0000-0000000000b1', 'b1@test.local', 'authenticated', 'authenticated'),
  ('00000000-0000-0000-0000-0000000000ff', 'pa@test.local', 'authenticated', 'authenticated'),
  ('00000000-0000-0000-0000-0000000000cc', 'x@test.local',  'authenticated', 'authenticated');

insert into public.platform_admins (user_id) values ('00000000-0000-0000-0000-0000000000ff');

-- DQR-T053: estos fixtures dan de alta como authenticated más miembros de los
-- que permite free (3): las orgs nacen en business (como postgres, sin UPDATE
-- para no generar filas de auditoría).
insert into public.organizations (id, name, slug, plan) values
  ('0000000a-0000-0000-0000-000000000000', 'Org A', 'org-a', 'business'),
  ('0000000b-0000-0000-0000-000000000000', 'Org B', 'org-b', 'business');

insert into public.memberships (org_id, user_id, role) values
  ('0000000a-0000-0000-0000-000000000000', '00000000-0000-0000-0000-0000000000a1', 'owner'),
  ('0000000a-0000-0000-0000-000000000000', '00000000-0000-0000-0000-0000000000a3', 'admin'),
  ('0000000a-0000-0000-0000-000000000000', '00000000-0000-0000-0000-0000000000e1', 'editor'),
  ('0000000a-0000-0000-0000-000000000000', '00000000-0000-0000-0000-0000000000a2', 'viewer'),
  ('0000000b-0000-0000-0000-000000000000', '00000000-0000-0000-0000-0000000000b1', 'owner');

insert into public.dynamic_links (id, org_id, slug, name, destination_url) values
  ('b0000000-0000-0000-0000-000000000001', '0000000b-0000-0000-0000-000000000000',
   'BBBBBB1', 'Link B', 'https://b.example.com/'),
  ('a0000000-0000-0000-0000-000000000001', '0000000a-0000-0000-0000-000000000000',
   'AAAAAA1', 'Link A', 'https://a.example.com/');

-- Simula una petición con el JWT de un usuario.
create function pg_temp.login(p_uid uuid) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub', p_uid, 'role', 'authenticated')::text, true);
  execute 'set local role authenticated';
end $$;

-- Simula el backend con la service key (JWT sin sub).
create function pg_temp.as_service() returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims', json_build_object('role', 'service_role')::text, true);
  execute 'set local role service_role';
end $$;

create function pg_temp.logout() returns void language plpgsql as $$
begin
  execute 'reset role';
  perform set_config('request.jwt.claims', '', true);
end $$;

-- Última fila de auditoría de una entidad (llamar como postgres).
create function pg_temp.last_audit(p_entity text, p_entity_id text)
returns public.audit_log language sql as $$
  select * from public.audit_log
  where entity = p_entity and entity_id = p_entity_id
  order by id desc limit 1;
$$;

create function pg_temp.audit_count(p_entity text, p_entity_id text)
returns bigint language sql as $$
  select count(*) from public.audit_log where entity = p_entity and entity_id = p_entity_id;
$$;

-- -----------------------------------------------------------------------------
-- Esquema, índices, privilegios y funciones
-- -----------------------------------------------------------------------------
select has_table('public', 'audit_log', 'existe audit_log');
select col_type_is('public', 'audit_log', 'id', 'bigint', 'id bigint');
select col_type_is('public', 'audit_log', 'org_id', 'uuid', 'org_id uuid');
select col_type_is('public', 'audit_log', 'actor', 'uuid', 'actor uuid');
select col_type_is('public', 'audit_log', 'action', 'text', 'action text');
select col_type_is('public', 'audit_log', 'entity', 'text', 'entity text');
select col_type_is('public', 'audit_log', 'entity_id', 'text', 'entity_id text');
select col_type_is('public', 'audit_log', 'diff', 'jsonb', 'diff jsonb');
select col_type_is('public', 'audit_log', 'at', 'timestamp with time zone', 'at timestamptz');
select is(
  (select attidentity::text from pg_attribute
   where attrelid = 'public.audit_log'::regclass and attname = 'id'),
  'a', 'id es identity GENERATED ALWAYS');
select col_not_null('public', 'audit_log', 'org_id', 'org_id NOT NULL');
select col_is_null('public', 'audit_log', 'actor', 'actor admite NULL (service_role / jobs)');

select is(
  (select indexdef from pg_indexes where schemaname = 'public' and indexname = 'audit_log_org_at_idx'),
  'CREATE INDEX audit_log_org_at_idx ON public.audit_log USING btree (org_id, at DESC)',
  'índice (org_id, at desc)');
select is(
  (select indexdef from pg_indexes where schemaname = 'public' and indexname = 'audit_log_entity_idx'),
  'CREATE INDEX audit_log_entity_idx ON public.audit_log USING btree (entity, entity_id)',
  'índice (entity, entity_id)');

select is(
  (select relrowsecurity from pg_class where oid = 'public.audit_log'::regclass),
  true, 'RLS activado en audit_log');
select policies_are('public', 'audit_log', array['audit_log_select'],
  'audit_log solo tiene política de SELECT');

select table_privs_are('public', 'audit_log', 'authenticated', array['SELECT'],
  'authenticated solo SELECT');
select table_privs_are('public', 'audit_log', 'service_role', array['SELECT'],
  'service_role solo SELECT');
select table_privs_are('public', 'audit_log', 'anon', array[]::text[],
  'anon sin privilegios');

select is(
  (select p.prosecdef from pg_proc p where p.oid = 'private.audit_row()'::regprocedure),
  true, 'audit_row es SECURITY DEFINER');
select is(
  (select p.proconfig from pg_proc p where p.oid = 'private.audit_row()'::regprocedure),
  array['search_path=""'], 'audit_row con search_path vacío');
select ok(
  not has_function_privilege('authenticated', 'private.audit_row()', 'execute')
  and not has_function_privilege('anon', 'private.audit_row()', 'execute'),
  'anon/authenticated no ejecutan audit_row');

-- sec-T052 H1: RLS por conjunto, no fila a fila.
select is(
  (select p.prosecdef from pg_proc p where p.oid = 'private.my_admin_org_ids()'::regprocedure),
  true, 'my_admin_org_ids es SECURITY DEFINER');
select is(
  (select p.proconfig from pg_proc p where p.oid = 'private.my_admin_org_ids()'::regprocedure),
  array['search_path=""'], 'my_admin_org_ids con search_path vacío');
select ok(
  not has_function_privilege('anon', 'private.my_admin_org_ids()', 'execute')
  and has_function_privilege('authenticated', 'private.my_admin_org_ids()', 'execute'),
  'my_admin_org_ids: authenticated sí, anon no');
select ok(
  (select qual from pg_policies
   where schemaname = 'public' and tablename = 'audit_log' and policyname = 'audit_log_select')
    ~ 'my_admin_org_ids' ,
  'audit_log_select usa my_admin_org_ids()');
select ok(
  (select qual from pg_policies
   where schemaname = 'public' and tablename = 'audit_log' and policyname = 'audit_log_select')
    !~ 'has_org_role',
  'audit_log_select no evalúa has_org_role fila a fila');

select has_trigger('public', 'dynamic_links', 'dynamic_links_audit', 'trigger en dynamic_links');
select has_trigger('public', 'memberships', 'memberships_audit', 'trigger en memberships');
select has_trigger('public', 'organizations', 'organizations_audit', 'trigger en organizations');
select has_trigger('public', 'nfc_tags', 'nfc_tags_audit', 'trigger en nfc_tags');
select has_trigger('public', 'qr_designs', 'qr_designs_audit', 'trigger en qr_designs');
select has_trigger('public', 'audit_log', 'audit_log_append_only', 'guarda append-only');
select has_trigger('public', 'audit_log', 'audit_log_no_truncate', 'guarda contra TRUNCATE');

-- Fixtures como postgres: membresías auditadas con actor NULL.
select is(
  (select row(action, actor, diff) from pg_temp.last_audit('member', '00000000-0000-0000-0000-0000000000a2')),
  row('member.created'::text, null::uuid,
      '{"role": {"old": null, "new": "viewer"}}'::jsonb),
  'fixture: alta de miembro sin JWT → member.created con actor NULL');
-- La creación de organizaciones no se audita (solo name/plan/status en UPDATE).
select is(pg_temp.audit_count('org', '0000000a-0000-0000-0000-000000000000'), 0::bigint,
  'alta de organización no se audita');

-- -----------------------------------------------------------------------------
-- Enlaces
-- -----------------------------------------------------------------------------
-- e1 (editor) crea un enlace.
select pg_temp.login('00000000-0000-0000-0000-0000000000e1');
insert into public.dynamic_links (org_id, name, destination_url)
values ('0000000a-0000-0000-0000-000000000000', 'Audit L1', 'https://a.example.com/one');
select pg_temp.logout();

create temp table t_link as
  select id::text as id, slug from public.dynamic_links where name = 'Audit L1';

select is(
  (select row(org_id, actor, action, entity) from pg_temp.last_audit('link', (select id from t_link))),
  row('0000000a-0000-0000-0000-000000000000'::uuid, '00000000-0000-0000-0000-0000000000e1'::uuid,
      'link.created'::text, 'link'::text),
  'INSERT enlace → link.created, org y actor correctos');
select is(
  (select diff from pg_temp.last_audit('link', (select id from t_link))),
  jsonb_build_object(
    'name',            jsonb_build_object('old', null, 'new', 'Audit L1'),
    'slug',            jsonb_build_object('old', null, 'new', (select slug from t_link)),
    'status',          jsonb_build_object('old', null, 'new', 'active'),
    'created_by',      jsonb_build_object('old', null, 'new', '00000000-0000-0000-0000-0000000000e1'),
    'destination_url', jsonb_build_object('old', null, 'new', 'https://a.example.com/one')),
  'link.created: diff con valores nuevos; sin nulos, id, org_id, created_at ni updated_at');

-- e1 cambia el destino.
select pg_temp.login('00000000-0000-0000-0000-0000000000e1');
update public.dynamic_links set destination_url = 'https://a.example.com/two'
  where name = 'Audit L1';
select pg_temp.logout();

select is(
  (select row(action, actor, diff) from pg_temp.last_audit('link', (select id from t_link))),
  row('link.destination_changed'::text, '00000000-0000-0000-0000-0000000000e1'::uuid,
      '{"destination_url": {"old": "https://a.example.com/one", "new": "https://a.example.com/two"}}'::jsonb),
  'cambio de destino → link.destination_changed con old/new y sin updated_at');

-- e1 renombra.
select pg_temp.login('00000000-0000-0000-0000-0000000000e1');
update public.dynamic_links set name = 'Audit L1 bis' where name = 'Audit L1';
select pg_temp.logout();

select is(
  (select row(action, diff) from pg_temp.last_audit('link', (select id from t_link))),
  row('link.updated'::text, '{"name": {"old": "Audit L1", "new": "Audit L1 bis"}}'::jsonb),
  'cambio sin verbo específico → link.updated');

-- UPDATE sin cambios reales (solo cambia updated_at por el guard): no se registra.
select pg_temp.login('00000000-0000-0000-0000-0000000000e1');
update public.dynamic_links set name = name where name = 'Audit L1 bis';
select pg_temp.logout();

select is(pg_temp.audit_count('link', (select id from t_link)), 3::bigint,
  'UPDATE sin cambios no genera fila');

-- Varias columnas a la vez: diff con todas; verbo por prioridad (destino).
select pg_temp.login('00000000-0000-0000-0000-0000000000e1');
update public.dynamic_links
  set destination_url = 'https://a.example.com/three', fallback_url = 'https://a.example.com/fb',
      status = 'paused'
  where name = 'Audit L1 bis';
select pg_temp.logout();

select is(
  (select row(action, diff) from pg_temp.last_audit('link', (select id from t_link))),
  row('link.destination_changed'::text,
      '{"destination_url": {"old": "https://a.example.com/two", "new": "https://a.example.com/three"},
        "fallback_url":    {"old": null, "new": "https://a.example.com/fb"},
        "status":          {"old": "active", "new": "paused"}}'::jsonb),
  'cambio múltiple → todas las columnas en el diff; verbo destination_changed');

-- a3 (admin) archiva.
select pg_temp.login('00000000-0000-0000-0000-0000000000a3');
update public.dynamic_links set status = 'archived' where name = 'Audit L1 bis';
select pg_temp.logout();

select is(
  (select row(action, actor, diff) from pg_temp.last_audit('link', (select id from t_link))),
  row('link.status_changed'::text, '00000000-0000-0000-0000-0000000000a3'::uuid,
      '{"status": {"old": "paused", "new": "archived"}}'::jsonb),
  'archivar → link.status_changed');

-- a3 borra: se conserva el último destino (H6 de T018).
select pg_temp.login('00000000-0000-0000-0000-0000000000a3');
delete from public.dynamic_links where name = 'Audit L1 bis';
select pg_temp.logout();

select is(
  (select row(action, actor) from pg_temp.last_audit('link', (select id from t_link))),
  row('link.deleted'::text, '00000000-0000-0000-0000-0000000000a3'::uuid),
  'DELETE enlace → link.deleted con actor');
select is(
  (select diff -> 'destination_url' from pg_temp.last_audit('link', (select id from t_link))),
  '{"old": "https://a.example.com/three", "new": null}'::jsonb,
  'link.deleted conserva el último destino');
select is(
  (select diff - 'slug' - 'created_by' from pg_temp.last_audit('link', (select id from t_link))),
  '{"name":            {"old": "Audit L1 bis", "new": null},
    "status":          {"old": "archived", "new": null},
    "fallback_url":    {"old": "https://a.example.com/fb", "new": null},
    "destination_url": {"old": "https://a.example.com/three", "new": null}}'::jsonb,
  'link.deleted: diff con los valores previos y new = null');
select is(pg_temp.audit_count('link', (select id from t_link)), 6::bigint,
  'el historial del enlace sobrevive a su borrado');

-- service_role escribe → actor NULL.
select pg_temp.as_service();
update public.dynamic_links set name = 'Link B svc'
  where id = 'b0000000-0000-0000-0000-000000000001';
select pg_temp.logout();

select is(
  (select row(org_id, actor, action) from pg_temp.last_audit('link', 'b0000000-0000-0000-0000-000000000001')),
  row('0000000b-0000-0000-0000-000000000000'::uuid, null::uuid, 'link.updated'::text),
  'cambio con service_role → actor NULL');

-- -----------------------------------------------------------------------------
-- Miembros
-- -----------------------------------------------------------------------------
select pg_temp.login('00000000-0000-0000-0000-0000000000a3');
insert into public.memberships (org_id, user_id, role)
values ('0000000a-0000-0000-0000-000000000000', '00000000-0000-0000-0000-0000000000cc', 'viewer');
select pg_temp.logout();

select is(
  (select row(org_id, actor, action, entity, diff) from pg_temp.last_audit('member', '00000000-0000-0000-0000-0000000000cc')),
  row('0000000a-0000-0000-0000-000000000000'::uuid, '00000000-0000-0000-0000-0000000000a3'::uuid,
      'member.created'::text, 'member'::text, '{"role": {"old": null, "new": "viewer"}}'::jsonb),
  'alta de miembro → member.created (entity_id = user_id)');

select pg_temp.login('00000000-0000-0000-0000-0000000000a3');
update public.memberships set role = 'editor'
  where org_id = '0000000a-0000-0000-0000-000000000000'
    and user_id = '00000000-0000-0000-0000-0000000000cc';
select pg_temp.logout();

select is(
  (select row(action, actor, diff) from pg_temp.last_audit('member', '00000000-0000-0000-0000-0000000000cc')),
  row('member.role_changed'::text, '00000000-0000-0000-0000-0000000000a3'::uuid,
      '{"role": {"old": "viewer", "new": "editor"}}'::jsonb),
  'cambio de rol → member.role_changed');

-- Mismo rol: no se registra.
select pg_temp.login('00000000-0000-0000-0000-0000000000a3');
update public.memberships set role = 'editor'
  where org_id = '0000000a-0000-0000-0000-000000000000'
    and user_id = '00000000-0000-0000-0000-0000000000cc';
select pg_temp.logout();

select is(pg_temp.audit_count('member', '00000000-0000-0000-0000-0000000000cc'), 2::bigint,
  'UPDATE de rol sin cambio no genera fila');

select pg_temp.login('00000000-0000-0000-0000-0000000000a3');
delete from public.memberships
  where org_id = '0000000a-0000-0000-0000-000000000000'
    and user_id = '00000000-0000-0000-0000-0000000000cc';
select pg_temp.logout();

select is(
  (select row(action, actor, diff) from pg_temp.last_audit('member', '00000000-0000-0000-0000-0000000000cc')),
  row('member.deleted'::text, '00000000-0000-0000-0000-0000000000a3'::uuid,
      '{"role": {"old": "editor", "new": null}}'::jsonb),
  'baja de miembro → member.deleted');

-- -----------------------------------------------------------------------------
-- Organizaciones (solo name, plan, status)
-- -----------------------------------------------------------------------------
select pg_temp.login('00000000-0000-0000-0000-0000000000a3');
update public.organizations set name = 'Org A2' where id = '0000000a-0000-0000-0000-000000000000';
select pg_temp.logout();

select is(
  (select row(org_id, actor, action, entity, diff) from pg_temp.last_audit('org', '0000000a-0000-0000-0000-000000000000')),
  row('0000000a-0000-0000-0000-000000000000'::uuid, '00000000-0000-0000-0000-0000000000a3'::uuid,
      'org.renamed'::text, 'org'::text, '{"name": {"old": "Org A", "new": "Org A2"}}'::jsonb),
  'renombrar org → org.renamed');

select pg_temp.login('00000000-0000-0000-0000-0000000000ff');
update public.organizations set plan = 'pro' where id = '0000000a-0000-0000-0000-000000000000';
select pg_temp.logout();

select is(
  (select row(action, actor, diff) from pg_temp.last_audit('org', '0000000a-0000-0000-0000-000000000000')),
  row('org.plan_changed'::text, '00000000-0000-0000-0000-0000000000ff'::uuid,
      '{"plan": {"old": "business", "new": "pro"}}'::jsonb),
  'platform admin cambia plan → org.plan_changed');

select pg_temp.login('00000000-0000-0000-0000-0000000000ff');
update public.organizations set status = 'suspended', plan = 'business'
  where id = '0000000a-0000-0000-0000-000000000000';
select pg_temp.logout();

select is(
  (select row(action, diff) from pg_temp.last_audit('org', '0000000a-0000-0000-0000-000000000000')),
  row('org.status_changed'::text,
      '{"status": {"old": "active", "new": "suspended"}, "plan": {"old": "pro", "new": "business"}}'::jsonb),
  'status + plan → org.status_changed con ambas columnas');

-- slug/limits no se auditan; name sin cambio tampoco.
select pg_temp.as_service();
update public.organizations set slug = 'org-a-2', limits = '{"max_links": 5}', name = 'Org A2'
  where id = '0000000a-0000-0000-0000-000000000000';
select pg_temp.logout();

select is(pg_temp.audit_count('org', '0000000a-0000-0000-0000-000000000000'), 3::bigint,
  'cambios de slug/limits (y name igual) no generan fila');

select pg_temp.as_service();
update public.organizations set status = 'active' where id = '0000000a-0000-0000-0000-000000000000';
select pg_temp.logout();

select is(
  (select row(action, actor) from pg_temp.last_audit('org', '0000000a-0000-0000-0000-000000000000')),
  row('org.status_changed'::text, null::uuid),
  'service_role reactiva la org → actor NULL');

-- -----------------------------------------------------------------------------
-- Etiquetas NFC y diseños QR
-- -----------------------------------------------------------------------------
select pg_temp.login('00000000-0000-0000-0000-0000000000e1');
insert into public.nfc_tags (link_id, org_id, label, location, uid)
values ('a0000000-0000-0000-0000-000000000001', '0000000a-0000-0000-0000-000000000000',
        'Mesa 1', 'Sala', '04:a2:5b:1c:2d:3e:4f');
select pg_temp.logout();

create temp table t_tag as select id::text as id from public.nfc_tags where label = 'Mesa 1';

select is(
  (select row(org_id, actor, action, entity, diff) from pg_temp.last_audit('nfc_tag', (select id from t_tag))),
  row('0000000a-0000-0000-0000-000000000000'::uuid, '00000000-0000-0000-0000-0000000000e1'::uuid,
      'nfc_tag.created'::text, 'nfc_tag'::text,
      '{"label":    {"old": null, "new": "Mesa 1"},
        "location": {"old": null, "new": "Sala"},
        "uid":      {"old": null, "new": "04A25B1C2D3E4F"},
        "link_id":  {"old": null, "new": "a0000000-0000-0000-0000-000000000001"}}'::jsonb),
  'alta de etiqueta NFC → nfc_tag.created con valores normalizados');

select pg_temp.login('00000000-0000-0000-0000-0000000000e1');
update public.nfc_tags set label = 'Mesa 2' where label = 'Mesa 1';
select pg_temp.logout();
select is(
  (select row(action, diff) from pg_temp.last_audit('nfc_tag', (select id from t_tag))),
  row('nfc_tag.renamed'::text, '{"label": {"old": "Mesa 1", "new": "Mesa 2"}}'::jsonb),
  'cambio de label → nfc_tag.renamed');

select pg_temp.login('00000000-0000-0000-0000-0000000000e1');
update public.nfc_tags set location = 'Terraza' where label = 'Mesa 2';
select pg_temp.logout();
select is(
  (select row(action, diff) from pg_temp.last_audit('nfc_tag', (select id from t_tag))),
  row('nfc_tag.moved'::text, '{"location": {"old": "Sala", "new": "Terraza"}}'::jsonb),
  'cambio de location → nfc_tag.moved');

select pg_temp.login('00000000-0000-0000-0000-0000000000e1');
update public.nfc_tags set uid = null where label = 'Mesa 2';
select pg_temp.logout();
select is(
  (select row(action, diff) from pg_temp.last_audit('nfc_tag', (select id from t_tag))),
  row('nfc_tag.uid_changed'::text, '{"uid": {"old": "04A25B1C2D3E4F", "new": null}}'::jsonb),
  'cambio de uid → nfc_tag.uid_changed');

select pg_temp.login('00000000-0000-0000-0000-0000000000e1');
insert into public.qr_designs (link_id, org_id, fg)
values ('a0000000-0000-0000-0000-000000000001', '0000000a-0000-0000-0000-000000000000', '#112233');
select pg_temp.logout();

select is(
  (select row(org_id, actor, action, entity, diff)
   from pg_temp.last_audit('qr_design', 'a0000000-0000-0000-0000-000000000001')),
  row('0000000a-0000-0000-0000-000000000000'::uuid, '00000000-0000-0000-0000-0000000000e1'::uuid,
      'qr_design.created'::text, 'qr_design'::text,
      '{"fg":        {"old": null, "new": "#112233"},
        "bg":        {"old": null, "new": "#FFFFFF"},
        "frame":     {"old": null, "new": "none"},
        "ecc_level": {"old": null, "new": "M"},
        "style":     {"old": null, "new": {}}}'::jsonb),
  'alta de diseño QR → qr_design.created (entity_id = link_id, sin updated_at)');

select pg_temp.login('00000000-0000-0000-0000-0000000000e1');
update public.qr_designs set fg = '#000000' where link_id = 'a0000000-0000-0000-0000-000000000001';
select pg_temp.logout();
select is(
  (select row(action, diff) from pg_temp.last_audit('qr_design', 'a0000000-0000-0000-0000-000000000001')),
  row('qr_design.updated'::text, '{"fg": {"old": "#112233", "new": "#000000"}}'::jsonb),
  'cambio de diseño → qr_design.updated sin updated_at');

-- Borrar el enlace audita también el borrado en cascada de etiqueta y diseño.
select pg_temp.login('00000000-0000-0000-0000-0000000000a3');
delete from public.dynamic_links where id = 'a0000000-0000-0000-0000-000000000001';
select pg_temp.logout();

select is(
  (select row(action, actor, diff -> 'label')
   from pg_temp.last_audit('nfc_tag', (select id from t_tag))),
  row('nfc_tag.deleted'::text, '00000000-0000-0000-0000-0000000000a3'::uuid,
      '{"old": "Mesa 2", "new": null}'::jsonb),
  'borrar el enlace → nfc_tag.deleted en cascada');
select is(
  (select row(action, actor, diff -> 'fg')
   from pg_temp.last_audit('qr_design', 'a0000000-0000-0000-0000-000000000001')),
  row('qr_design.deleted'::text, '00000000-0000-0000-0000-0000000000a3'::uuid,
      '{"old": "#000000", "new": null}'::jsonb),
  'borrar el enlace → qr_design.deleted en cascada');

-- -----------------------------------------------------------------------------
-- Lectura (RLS): admin+ y platform admin
-- -----------------------------------------------------------------------------
select pg_temp.login('00000000-0000-0000-0000-0000000000a3');
select is(array(select private.my_admin_org_ids()),
  array['0000000a-0000-0000-0000-000000000000'::uuid], 'my_admin_org_ids: admin de A → {A}');
select pg_temp.logout();
select pg_temp.login('00000000-0000-0000-0000-0000000000a1');
select is(array(select private.my_admin_org_ids()),
  array['0000000a-0000-0000-0000-000000000000'::uuid], 'my_admin_org_ids: owner de A → {A}');
select pg_temp.logout();
select pg_temp.login('00000000-0000-0000-0000-0000000000e1');
select is(array(select private.my_admin_org_ids()), array[]::uuid[],
  'my_admin_org_ids: editor → vacío');
select pg_temp.logout();
select pg_temp.login('00000000-0000-0000-0000-0000000000a2');
select is(array(select private.my_admin_org_ids()), array[]::uuid[],
  'my_admin_org_ids: viewer → vacío');
select pg_temp.logout();

-- Un extraño (como un GET de PostgREST): filtro por conjunto (hashed SubPlan),
-- sin llamadas a has_org_role por fila.
create function pg_temp.explain_text(p_sql text) returns text language plpgsql as $$
declare v_line text; v_out text := '';
begin
  for v_line in execute 'explain ' || p_sql loop
    v_out := v_out || v_line || E'\n';
  end loop;
  return v_out;
end $$;

select pg_temp.login('00000000-0000-0000-0000-0000000000cc');
select ok(
  pg_temp.explain_text('select * from public.audit_log order by id desc limit 20') ~ 'hashed SubPlan',
  'extraño: la RLS se resuelve con un hashed SubPlan (una vez por consulta)');
select ok(
  pg_temp.explain_text('select * from public.audit_log order by id desc limit 20') !~ 'has_org_role',
  'extraño: el plan no llama a has_org_role por fila');
select pg_temp.logout();

select pg_temp.login('00000000-0000-0000-0000-0000000000a2');
select is((select count(*) from public.audit_log), 0::bigint, 'viewer no lee audit_log');
select pg_temp.logout();

select pg_temp.login('00000000-0000-0000-0000-0000000000e1');
select is((select count(*) from public.audit_log), 0::bigint, 'editor no lee audit_log');
select pg_temp.logout();

select pg_temp.login('00000000-0000-0000-0000-0000000000cc');
select is((select count(*) from public.audit_log), 0::bigint, 'usuario sin org no lee audit_log');
select pg_temp.logout();

select pg_temp.login('00000000-0000-0000-0000-0000000000a3');
select ok((select count(*) from public.audit_log) > 0, 'admin lee audit_log de su org');
select is(
  (select count(*) from public.audit_log where org_id <> '0000000a-0000-0000-0000-000000000000'),
  0::bigint, 'admin de A no ve filas de B');
select is(
  (select count(*) from public.audit_log),
  (select count(*) from public.audit_log where org_id = '0000000a-0000-0000-0000-000000000000'),
  'admin de A: todas las filas visibles son de A');
select pg_temp.logout();

select pg_temp.login('00000000-0000-0000-0000-0000000000a1');
select ok((select count(*) from public.audit_log) > 0, 'owner lee audit_log de su org');
select pg_temp.logout();

select pg_temp.login('00000000-0000-0000-0000-0000000000b1');
select ok((select count(*) from public.audit_log) > 0, 'owner de B lee audit_log de B');
select is(
  (select count(*) from public.audit_log where org_id <> '0000000b-0000-0000-0000-000000000000'),
  0::bigint, 'owner de B no ve filas de A');
select pg_temp.logout();

select pg_temp.login('00000000-0000-0000-0000-0000000000ff');
select is(
  (select count(distinct org_id) from public.audit_log
   where org_id in ('0000000a-0000-0000-0000-000000000000', '0000000b-0000-0000-0000-000000000000')),
  2::bigint, 'platform admin lee ambas orgs');
select pg_temp.logout();

-- service_role lee (bypassrls).
select pg_temp.as_service();
select ok((select count(*) from public.audit_log) > 0, 'service_role lee audit_log');
select pg_temp.logout();

set local role anon;
select throws_ok('select count(*) from public.audit_log', '42501', null, 'anon no lee audit_log');
reset role;

-- -----------------------------------------------------------------------------
-- Append-only: nadie inserta, actualiza ni borra
-- -----------------------------------------------------------------------------
select pg_temp.login('00000000-0000-0000-0000-0000000000a3');
select throws_ok(
  $$insert into public.audit_log (org_id, action, entity, entity_id)
    values ('0000000a-0000-0000-0000-000000000000', 'link.created', 'link', 'x')$$,
  '42501', null, 'admin no inserta en audit_log');
select throws_ok(
  $$update public.audit_log set diff = '{}' where org_id = '0000000a-0000-0000-0000-000000000000'$$,
  '42501', null, 'admin no actualiza audit_log');
select throws_ok(
  $$delete from public.audit_log where org_id = '0000000a-0000-0000-0000-000000000000'$$,
  '42501', null, 'admin no borra audit_log');
select throws_ok('truncate public.audit_log', '42501', null, 'admin no trunca audit_log');
select pg_temp.logout();

select pg_temp.login('00000000-0000-0000-0000-0000000000ff');
select throws_ok(
  $$update public.audit_log set actor = null$$,
  '42501', null, 'platform admin no actualiza audit_log');
select throws_ok(
  $$delete from public.audit_log$$,
  '42501', null, 'platform admin no borra audit_log');
select pg_temp.logout();

select pg_temp.as_service();
select throws_ok(
  $$insert into public.audit_log (org_id, action, entity, entity_id)
    values ('0000000a-0000-0000-0000-000000000000', 'link.created', 'link', 'x')$$,
  '42501', null, 'service_role no inserta en audit_log');
select throws_ok(
  $$update public.audit_log set diff = '{}'$$,
  '42501', null, 'service_role no actualiza audit_log');
select throws_ok(
  $$delete from public.audit_log$$,
  '42501', null, 'service_role no borra audit_log');
select pg_temp.logout();

-- Ni siquiera el owner de la tabla (postgres).
select throws_ok(
  $$update public.audit_log set diff = '{}'$$,
  '42501', 'audit_log es append-only: UPDATE no permitido', 'postgres no actualiza audit_log');
select throws_ok(
  $$delete from public.audit_log$$,
  '42501', 'audit_log es append-only: DELETE no permitido', 'postgres no borra audit_log');
select throws_ok(
  'truncate public.audit_log',
  '42501', 'audit_log es append-only: TRUNCATE no permitido', 'postgres no trunca audit_log');

-- -----------------------------------------------------------------------------
-- Borrado de una organización: la auditoría sobrevive
-- -----------------------------------------------------------------------------
select pg_temp.login('00000000-0000-0000-0000-0000000000b1');
delete from public.organizations where id = '0000000b-0000-0000-0000-000000000000';
select pg_temp.logout();

select is(
  (select row(org_id, action, actor) from pg_temp.last_audit('link', 'b0000000-0000-0000-0000-000000000001')),
  row('0000000b-0000-0000-0000-000000000000'::uuid, 'link.deleted'::text,
      '00000000-0000-0000-0000-0000000000b1'::uuid),
  'borrar la org registra el borrado en cascada de sus enlaces');
select is(
  (select row(org_id, action) from pg_temp.last_audit('member', '00000000-0000-0000-0000-0000000000b1')),
  row('0000000b-0000-0000-0000-000000000000'::uuid, 'member.deleted'::text),
  'borrar la org registra el borrado en cascada de sus miembros');

select pg_temp.login('00000000-0000-0000-0000-0000000000b1');
select is((select count(*) from public.audit_log), 0::bigint,
  'ex-owner ya no lee la auditoría de la org borrada');
select pg_temp.logout();

select pg_temp.login('00000000-0000-0000-0000-0000000000ff');
select ok(
  (select count(*) from public.audit_log where org_id = '0000000b-0000-0000-0000-000000000000') > 0,
  'platform admin sigue leyendo la auditoría de la org borrada');
select pg_temp.logout();

select * from finish();
rollback;
