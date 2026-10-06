-- DQR-T034 · Tests de nfc_tags, FK scan_events.tag_id y record_scan (pgTAP).
-- Ejecutar: supabase test db. Todo corre dentro de BEGIN … ROLLBACK: no deja datos.
begin;

create extension if not exists pgtap with schema extensions;

select plan(96);

-- -----------------------------------------------------------------------------
-- Fixtures (como postgres)
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

insert into public.organizations (id, name, slug) values
  ('0000000a-0000-0000-0000-000000000000', 'Org A', 'org-a'),
  ('0000000b-0000-0000-0000-000000000000', 'Org B', 'org-b');

insert into public.memberships (org_id, user_id, role) values
  ('0000000a-0000-0000-0000-000000000000', '00000000-0000-0000-0000-0000000000a1', 'owner'),
  ('0000000a-0000-0000-0000-000000000000', '00000000-0000-0000-0000-0000000000a3', 'admin'),
  ('0000000a-0000-0000-0000-000000000000', '00000000-0000-0000-0000-0000000000e1', 'editor'),
  ('0000000a-0000-0000-0000-000000000000', '00000000-0000-0000-0000-0000000000a2', 'viewer'),
  ('0000000b-0000-0000-0000-000000000000', '00000000-0000-0000-0000-0000000000b1', 'owner');

insert into public.dynamic_links (id, org_id, slug, name, destination_url) values
  ('a0000000-0000-0000-0000-000000000001', '0000000a-0000-0000-0000-000000000000',
   'NfcA001', 'Link A', 'https://a.example.com/'),
  ('a0000000-0000-0000-0000-000000000002', '0000000a-0000-0000-0000-000000000000',
   'NfcA002', 'Link A2', 'https://a.example.com/2'),
  ('b0000000-0000-0000-0000-000000000001', '0000000b-0000-0000-0000-000000000000',
   'NfcB001', 'Link B', 'https://b.example.com/');

-- Etiquetas: dos en A (enlaces 1 y 2) y una en B.
insert into public.nfc_tags (id, link_id, org_id, label, location, uid) values
  ('7a000000-0000-0000-0000-000000000001', 'a0000000-0000-0000-0000-000000000001',
   '0000000a-0000-0000-0000-000000000000', 'Mesa 1', 'Sala', '04:a2:5b:1c:2d:3e:4f'),
  ('7a000000-0000-0000-0000-000000000002', 'a0000000-0000-0000-0000-000000000002',
   '0000000a-0000-0000-0000-000000000000', 'Puerta', null, null),
  ('7b000000-0000-0000-0000-000000000001', 'b0000000-0000-0000-0000-000000000001',
   '0000000b-0000-0000-0000-000000000000', 'Stand B', 'Hall 2', '04 A2 5B 1C 2D 3E 4F');

create function pg_temp.login(p_uid uuid) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub', p_uid, 'role', 'authenticated')::text, true);
  execute 'set local role authenticated';
end $$;

create function pg_temp.as_role(p_role text) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims',
    json_build_object('role', p_role)::text, true);
  execute format('set local role %I', p_role);
end $$;

create function pg_temp.logout() returns void language plpgsql as $$
begin
  execute 'reset role';
  perform set_config('request.jwt.claims', '', true);
end $$;

-- record_scan y luego lee el evento en otra sentencia (otro snapshot). Devuelve
-- 'canal|tag_id' y falla si el evento no se guardó.
create function pg_temp.scan(p_link uuid, p_org uuid, p_channel text, p_tag uuid)
returns text language plpgsql volatile as $$
declare v_id bigint; v_out text;
begin
  v_id := public.record_scan(p_link, p_org, p_channel, p_tag_id => p_tag);
  select e.channel::text || '|' || coalesce(e.tag_id::text, 'NULL') into strict v_out
  from public.scan_events e where e.id = v_id;
  return v_out;
end $$;

-- -----------------------------------------------------------------------------
-- Esquema, índices y privilegios
-- -----------------------------------------------------------------------------
select has_table('public', 'nfc_tags', 'existe nfc_tags');
select ok((select relrowsecurity from pg_class where oid = 'public.nfc_tags'::regclass),
  'RLS habilitado en nfc_tags');
select col_type_is('public', 'nfc_tags', 'id', 'uuid', 'id es uuid');
select col_default_is('public', 'nfc_tags', 'id', 'gen_random_uuid()', 'id default gen_random_uuid()');
select col_not_null('public', 'nfc_tags', 'org_id', 'org_id NOT NULL');
select col_not_null('public', 'nfc_tags', 'link_id', 'link_id NOT NULL');
select col_is_null('public', 'nfc_tags', 'location', 'location opcional');
select col_is_null('public', 'nfc_tags', 'uid', 'uid opcional');
select col_default_is('public', 'nfc_tags', 'created_at', 'now()', 'created_at default now()');

select fk_ok('public', 'nfc_tags', array['link_id', 'org_id'],
             'public', 'dynamic_links', array['id', 'org_id'],
  'FK compuesta (link_id, org_id) → dynamic_links (id, org_id)');
select is((select confdeltype::text from pg_constraint where conname = 'nfc_tags_link_org_fkey'),
  'c', 'la FK de nfc_tags es on delete cascade');
select ok(exists (select 1 from pg_constraint
                  where conname = 'nfc_tags_id_link_key' and contype = 'u'
                    and conrelid = 'public.nfc_tags'::regclass),
  'nfc_tags tiene unique (id, link_id)');
select ok(exists (select 1 from pg_constraint
                  where conname = 'nfc_tags_org_uid_key' and contype = 'u'
                    and conrelid = 'public.nfc_tags'::regclass),
  'nfc_tags tiene unique (org_id, uid)');
select has_index('public', 'nfc_tags', 'nfc_tags_link_idx', array['link_id', 'created_at'],
  'índice (link_id, created_at)');

select fk_ok('public', 'scan_events', array['tag_id', 'link_id'],
             'public', 'nfc_tags', array['id', 'link_id'],
  'FK compuesta scan_events (tag_id, link_id) → nfc_tags (id, link_id)');
select results_eq(
  $$ select c.confdeltype::text, c.convalidated,
            (select array_agg(a.attname::text collate "default") from pg_attribute a
             where a.attrelid = c.conrelid and a.attnum = any (c.confdelsetcols))
     from pg_constraint c where c.conname = 'scan_events_tag_link_fkey' $$,
  $$ values ('n', true, array['tag_id']) $$,
  'la FK de scan_events es on delete set null (tag_id) y está validada');
select has_index('public', 'scan_events', 'scan_events_tag_occurred_idx', array['tag_id', 'occurred_at'],
  'índice (tag_id, occurred_at) en scan_events');

select ok(not has_table_privilege('anon', 'public.nfc_tags', 'select,insert,update,delete,truncate'),
  'anon no tiene privilegios sobre nfc_tags');
select ok(has_table_privilege('authenticated', 'public.nfc_tags', 'select,delete'),
  'authenticated puede leer y borrar (filtrado por RLS)');
select ok(not has_table_privilege('authenticated', 'public.nfc_tags', 'truncate,references,trigger'),
  'authenticated sin truncate/references/trigger');
select ok(
  has_column_privilege('authenticated', 'public.nfc_tags', 'link_id', 'insert')
  and has_column_privilege('authenticated', 'public.nfc_tags', 'org_id', 'insert')
  and has_column_privilege('authenticated', 'public.nfc_tags', 'label', 'insert')
  and has_column_privilege('authenticated', 'public.nfc_tags', 'location', 'insert')
  and has_column_privilege('authenticated', 'public.nfc_tags', 'uid', 'insert'),
  'authenticated inserta link_id, org_id, label, location y uid');
select ok(
  not has_column_privilege('authenticated', 'public.nfc_tags', 'id', 'insert')
  and not has_column_privilege('authenticated', 'public.nfc_tags', 'created_at', 'insert'),
  'authenticated no fija id ni created_at');
select ok(
  has_column_privilege('authenticated', 'public.nfc_tags', 'label', 'update')
  and has_column_privilege('authenticated', 'public.nfc_tags', 'location', 'update')
  and has_column_privilege('authenticated', 'public.nfc_tags', 'uid', 'update'),
  'authenticated edita label, location y uid');
select ok(
  not has_column_privilege('authenticated', 'public.nfc_tags', 'id', 'update')
  and not has_column_privilege('authenticated', 'public.nfc_tags', 'link_id', 'update')
  and not has_column_privilege('authenticated', 'public.nfc_tags', 'org_id', 'update')
  and not has_column_privilege('authenticated', 'public.nfc_tags', 'created_at', 'update'),
  'authenticated no cambia id, link_id, org_id ni created_at');
select ok(has_table_privilege('service_role', 'public.nfc_tags', 'select,insert,update,delete'),
  'service_role lee y escribe');

-- record_scan conserva firma, SECURITY DEFINER, search_path y grants.
select ok(
  (select p.prosecdef and p.proconfig @> array['search_path=""']
          and pg_get_userbyid(p.proowner) = 'postgres'
   from pg_proc p
   where p.oid = 'public.record_scan(uuid, uuid, text, uuid, text, text, text, text, text, text, boolean)'::regprocedure),
  'record_scan: SECURITY DEFINER, search_path vacío, propietario postgres');
select is((select count(*)::int from pg_proc where proname = 'record_scan'
             and pronamespace = 'public'::regnamespace), 1,
  'record_scan sigue teniendo una sola firma');
select ok(
  not has_function_privilege('anon',
    'public.record_scan(uuid, uuid, text, uuid, text, text, text, text, text, text, boolean)', 'execute')
  and not has_function_privilege('authenticated',
    'public.record_scan(uuid, uuid, text, uuid, text, text, text, text, text, text, boolean)', 'execute')
  and has_function_privilege('service_role',
    'public.record_scan(uuid, uuid, text, uuid, text, text, text, text, text, text, boolean)', 'execute'),
  'record_scan: EXECUTE solo para service_role');
select ok(
  not exists (select 1
              from pg_proc p, aclexplode(p.proacl) a
              where p.oid = 'public.record_scan(uuid, uuid, text, uuid, text, text, text, text, text, text, boolean)'::regprocedure
                and a.grantee = 0 and a.privilege_type = 'EXECUTE'),
  'PUBLIC no tiene EXECUTE sobre record_scan');

-- -----------------------------------------------------------------------------
-- CHECKs, normalización e inmutabilidad (como postgres: aplica a todos los roles)
-- -----------------------------------------------------------------------------
select is((select uid from public.nfc_tags where id = '7a000000-0000-0000-0000-000000000001'),
  '04A25B1C2D3E4F', 'uid normalizado: sin ":" y en mayúsculas');
select is((select uid from public.nfc_tags where id = '7b000000-0000-0000-0000-000000000001'),
  '04A25B1C2D3E4F', 'uid normalizado: sin espacios');

select throws_ok($$ insert into public.nfc_tags (link_id, org_id, label)
  values ('a0000000-0000-0000-0000-000000000001', '0000000b-0000-0000-0000-000000000000', 'X') $$,
  '23503', null, 'org_id distinto al del enlace rechazado (FK compuesta)');
select throws_ok($$ insert into public.nfc_tags (link_id, org_id, label)
  values ('a0000000-0000-0000-0000-0000000000ee', '0000000a-0000-0000-0000-000000000000', 'X') $$,
  '23503', null, 'enlace inexistente rechazado');
select throws_ok($$ insert into public.nfc_tags (link_id, org_id, label)
  values ('a0000000-0000-0000-0000-000000000001', '0000000a-0000-0000-0000-000000000000', '   ') $$,
  '23514', null, 'label vacío rechazado');
select throws_ok($$ insert into public.nfc_tags (link_id, org_id, label)
  values ('a0000000-0000-0000-0000-000000000001', '0000000a-0000-0000-0000-000000000000', repeat('l', 81)) $$,
  '23514', null, 'label de 81 caracteres rechazado');
select throws_ok($$ insert into public.nfc_tags (link_id, org_id, label)
  values ('a0000000-0000-0000-0000-000000000001', '0000000a-0000-0000-0000-000000000000', E'Mesa\x01') $$,
  '23514', null, 'label con caracteres de control rechazado');
select throws_ok($$ insert into public.nfc_tags (link_id, org_id, label)
  values ('a0000000-0000-0000-0000-000000000001', '0000000a-0000-0000-0000-000000000000', E'Mesa \u202Egnp.exe') $$,
  '23514', null, 'label con formato Unicode (RLO U+202E) rechazado');
select throws_ok($$ insert into public.nfc_tags (link_id, org_id, label, location)
  values ('a0000000-0000-0000-0000-000000000001', '0000000a-0000-0000-0000-000000000000', 'X',
          E'Sala\u200B\uFEFF') $$,
  '23514', null, 'location con formato Unicode (ZWSP, BOM) rechazada');
select throws_ok($$ insert into public.nfc_tags (link_id, org_id, label, location)
  values ('a0000000-0000-0000-0000-000000000001', '0000000a-0000-0000-0000-000000000000', 'X',
          repeat('l', 121)) $$,
  '23514', null, 'location de 121 caracteres rechazada');
select throws_ok($$ insert into public.nfc_tags (link_id, org_id, label, uid)
  values ('a0000000-0000-0000-0000-000000000001', '0000000a-0000-0000-0000-000000000000', 'X', 'zz:11:22:33') $$,
  '23514', null, 'uid no hex rechazado');
select throws_ok($$ insert into public.nfc_tags (link_id, org_id, label, uid)
  values ('a0000000-0000-0000-0000-000000000001', '0000000a-0000-0000-0000-000000000000', 'X', '0102030405') $$,
  '23514', null, 'uid de 5 bytes rechazado (solo 4, 7 o 10)');
select throws_ok($$ insert into public.nfc_tags (link_id, org_id, label, uid)
  values ('a0000000-0000-0000-0000-000000000002', '0000000a-0000-0000-0000-000000000000', 'X',
          '04-A2-5B-1C-2D-3E-4F') $$,
  '23505', null, 'uid repetido en la misma org rechazado (aunque cambie el formato)');

select lives_ok($$ insert into public.nfc_tags (link_id, org_id, label, location, uid) values
  ('a0000000-0000-0000-0000-000000000001', '0000000a-0000-0000-0000-000000000000', '  Barra  ', '   ', null),
  ('a0000000-0000-0000-0000-000000000001', '0000000a-0000-0000-0000-000000000000', 'Caja', null, 'deadbeef'),
  ('a0000000-0000-0000-0000-000000000001', '0000000a-0000-0000-0000-000000000000', 'Caja 2', null,
   '0102030405060708090A') $$,
  'uid de 4 y 10 bytes válidos; varias etiquetas sin uid en la misma org');
select results_eq(
  $$ select label, location from public.nfc_tags where label = 'Barra' $$,
  $$ values ('Barra'::text, null::text) $$,
  'label recortado y location vacía → NULL');
select is((select uid from public.nfc_tags where label = 'Caja'), 'DEADBEEF', 'uid de 4 bytes en mayúsculas');

select throws_ok($$ update public.nfc_tags set link_id = 'a0000000-0000-0000-0000-000000000002'
  where id = '7a000000-0000-0000-0000-000000000001' $$,
  '42501', null, 'link_id inmutable (también para postgres/service_role)');
select throws_ok($$ update public.nfc_tags set org_id = '0000000b-0000-0000-0000-000000000000'
  where id = '7a000000-0000-0000-0000-000000000001' $$,
  '42501', null, 'org_id inmutable');
select throws_ok($$ update public.nfc_tags set id = gen_random_uuid()
  where id = '7a000000-0000-0000-0000-000000000001' $$,
  '42501', null, 'id inmutable');

-- -----------------------------------------------------------------------------
-- RLS por rol y aislamiento A/B
-- -----------------------------------------------------------------------------
-- A tiene 5 etiquetas (2 fixtures + 3 de arriba); B tiene 1.
select pg_temp.login('00000000-0000-0000-0000-0000000000a2');  -- viewer A
select is((select count(*)::int from public.nfc_tags), 5, 'viewer de A ve las 5 etiquetas de A');
select is((select count(*)::int from public.nfc_tags
           where org_id = '0000000b-0000-0000-0000-000000000000'), 0, 'viewer de A no ve etiquetas de B');
select throws_ok($$ insert into public.nfc_tags (link_id, org_id, label)
  values ('a0000000-0000-0000-0000-000000000001', '0000000a-0000-0000-0000-000000000000', 'V') $$,
  '42501', null, 'viewer no puede crear etiquetas');
select is_empty($$ update public.nfc_tags set label = 'hack' returning id $$,
  'viewer no puede editar etiquetas');
select is_empty($$ delete from public.nfc_tags returning id $$, 'viewer no puede borrar etiquetas');
select pg_temp.logout();

select pg_temp.login('00000000-0000-0000-0000-0000000000e1');  -- editor A
select lives_ok($$ insert into public.nfc_tags (link_id, org_id, label, location)
  values ('a0000000-0000-0000-0000-000000000002', '0000000a-0000-0000-0000-000000000000',
          'Editor tag', 'Planta 1') $$,
  'editor crea una etiqueta en su org');
select throws_ok($$ insert into public.nfc_tags (link_id, org_id, label)
  values ('b0000000-0000-0000-0000-000000000001', '0000000b-0000-0000-0000-000000000000', 'E') $$,
  '42501', null, 'editor de A no crea etiquetas en B');
select throws_ok($$ insert into public.nfc_tags (link_id, org_id, label)
  values ('b0000000-0000-0000-0000-000000000001', '0000000a-0000-0000-0000-000000000000', 'E') $$,
  '23503', null, 'editor de A no cuelga una etiqueta de un enlace de B con org_id de A');
select throws_ok($$ insert into public.nfc_tags (id, link_id, org_id, label)
  values (gen_random_uuid(), 'a0000000-0000-0000-0000-000000000001', '0000000a-0000-0000-0000-000000000000', 'E') $$,
  '42501', null, 'editor no puede fijar el id');
select results_eq(
  $$ update public.nfc_tags set label = 'Mesa 1 (terraza)', location = 'Terraza', uid = '04:a2:5b:1c:2d:3e:50'
     where id = '7a000000-0000-0000-0000-000000000001' returning label, location, uid $$,
  $$ values ('Mesa 1 (terraza)'::text, 'Terraza'::text, '04A25B1C2D3E50'::text) $$,
  'editor edita label, location y uid (normalizado)');
select throws_ok($$ update public.nfc_tags set link_id = 'a0000000-0000-0000-0000-000000000002'
  where id = '7a000000-0000-0000-0000-000000000001' $$,
  '42501', null, 'editor no puede cambiar link_id (sin grant de columna)');
select throws_ok($$ update public.nfc_tags set org_id = '0000000b-0000-0000-0000-000000000000'
  where id = '7a000000-0000-0000-0000-000000000001' $$,
  '42501', null, 'editor no puede cambiar org_id (sin grant de columna)');
select is_empty($$ update public.nfc_tags set label = 'hack'
  where id = '7b000000-0000-0000-0000-000000000001' returning id $$,
  'editor de A no edita etiquetas de B');
select is_empty($$ delete from public.nfc_tags
  where id = '7a000000-0000-0000-0000-000000000002' returning id $$,
  'editor no puede borrar etiquetas');
select pg_temp.logout();

select pg_temp.login('00000000-0000-0000-0000-0000000000a3');  -- admin A
select results_eq($$ delete from public.nfc_tags where label = 'Editor tag' returning label $$,
  $$ values ('Editor tag'::text) $$, 'admin borra una etiqueta de su org');
select is_empty($$ delete from public.nfc_tags
  where id = '7b000000-0000-0000-0000-000000000001' returning id $$,
  'admin de A no borra etiquetas de B');
select pg_temp.logout();

select pg_temp.login('00000000-0000-0000-0000-0000000000b1');  -- owner B
select is((select count(*)::int from public.nfc_tags), 1, 'owner de B ve solo su etiqueta');
select is((select count(*)::int from public.nfc_tags
           where org_id = '0000000a-0000-0000-0000-000000000000'), 0, 'owner de B no ve etiquetas de A');
select is_empty($$ update public.nfc_tags set label = 'hack'
  where id = '7a000000-0000-0000-0000-000000000001' returning id $$,
  'owner de B no edita etiquetas de A');
select is_empty($$ delete from public.nfc_tags
  where id = '7a000000-0000-0000-0000-000000000001' returning id $$,
  'owner de B no borra etiquetas de A');
select throws_ok($$ insert into public.nfc_tags (link_id, org_id, label)
  values ('a0000000-0000-0000-0000-000000000001', '0000000a-0000-0000-0000-000000000000', 'B') $$,
  '42501', null, 'owner de B no crea etiquetas en A');
select lives_ok($$ insert into public.nfc_tags (link_id, org_id, label, uid)
  values ('b0000000-0000-0000-0000-000000000001', '0000000b-0000-0000-0000-000000000000', 'B2', 'DEADBEEF') $$,
  'el mismo uid puede existir en otra org');
select pg_temp.logout();

select pg_temp.login('00000000-0000-0000-0000-0000000000cc');  -- sin org
select is((select count(*)::int from public.nfc_tags), 0, 'usuario sin org no ve etiquetas');
select throws_ok($$ insert into public.nfc_tags (link_id, org_id, label)
  values ('a0000000-0000-0000-0000-000000000001', '0000000a-0000-0000-0000-000000000000', 'C') $$,
  '42501', null, 'usuario sin org no crea etiquetas');
select pg_temp.logout();

select pg_temp.login('00000000-0000-0000-0000-0000000000ff');  -- platform admin
select is((select count(*)::int from public.nfc_tags), 7, 'platform admin ve todas las etiquetas');
select lives_ok($$ insert into public.nfc_tags (link_id, org_id, label)
  values ('b0000000-0000-0000-0000-000000000001', '0000000b-0000-0000-0000-000000000000', 'PA') $$,
  'platform admin crea etiquetas en cualquier org');
select results_eq($$ delete from public.nfc_tags where label = 'PA' returning label $$,
  $$ values ('PA'::text) $$, 'platform admin borra etiquetas');
select pg_temp.logout();

select pg_temp.as_role('anon');
select throws_ok($$ select count(*) from public.nfc_tags $$, '42501', null, 'anon no lee nfc_tags');
select throws_ok($$ insert into public.nfc_tags (link_id, org_id, label)
  values ('a0000000-0000-0000-0000-000000000001', '0000000a-0000-0000-0000-000000000000', 'N') $$,
  '42501', null, 'anon no crea etiquetas');
select pg_temp.logout();

-- -----------------------------------------------------------------------------
-- FK scan_events (tag_id, link_id) → nfc_tags (id, link_id)
-- -----------------------------------------------------------------------------
select lives_ok($$ insert into public.scan_events (link_id, org_id, channel, tag_id)
  values ('a0000000-0000-0000-0000-000000000001', '0000000a-0000-0000-0000-000000000000', 'nfc',
          '7a000000-0000-0000-0000-000000000001') $$,
  'evento con una etiqueta de su enlace');
select throws_ok($$ insert into public.scan_events (link_id, org_id, channel, tag_id)
  values ('a0000000-0000-0000-0000-000000000001', '0000000a-0000-0000-0000-000000000000', 'nfc',
          '7a000000-0000-0000-0000-000000000002') $$,
  '23503', null, 'evento con una etiqueta de otro enlace de la misma org rechazado');
select throws_ok($$ insert into public.scan_events (link_id, org_id, channel, tag_id)
  values ('a0000000-0000-0000-0000-000000000001', '0000000a-0000-0000-0000-000000000000', 'nfc',
          '7b000000-0000-0000-0000-000000000001') $$,
  '23503', null, 'evento con una etiqueta de otra org rechazado');
select throws_ok($$ insert into public.scan_events (link_id, org_id, channel, tag_id)
  values ('a0000000-0000-0000-0000-000000000001', '0000000a-0000-0000-0000-000000000000', 'nfc',
          '7f000000-0000-0000-0000-0000000000ee') $$,
  '23503', null, 'evento con una etiqueta inexistente rechazado');
select lives_ok($$ insert into public.scan_events (link_id, org_id, channel)
  values ('a0000000-0000-0000-0000-000000000001', '0000000a-0000-0000-0000-000000000000', 'nfc') $$,
  'evento nfc sin etiqueta sigue permitido');

-- -----------------------------------------------------------------------------
-- record_scan como service_role
-- -----------------------------------------------------------------------------
select pg_temp.as_role('service_role');
select is(
  pg_temp.scan('a0000000-0000-0000-0000-000000000001', '0000000a-0000-0000-0000-000000000000', 'nfc', '7a000000-0000-0000-0000-000000000001'::uuid),
  'nfc|7a000000-0000-0000-0000-000000000001',
  'record_scan guarda una etiqueta propia del enlace');
select is(
  pg_temp.scan('a0000000-0000-0000-0000-000000000001', '0000000a-0000-0000-0000-000000000000', 'nfc', '7b000000-0000-0000-0000-000000000001'::uuid),
  'nfc|NULL',
  'record_scan con una etiqueta de otra org → tag_id NULL (no falla)');
select is(
  pg_temp.scan('a0000000-0000-0000-0000-000000000001', '0000000a-0000-0000-0000-000000000000', 'nfc', '7a000000-0000-0000-0000-000000000002'::uuid),
  'nfc|NULL',
  'record_scan con una etiqueta de otro enlace de la misma org → tag_id NULL');
select is(
  pg_temp.scan('a0000000-0000-0000-0000-000000000001', '0000000a-0000-0000-0000-000000000000', 'nfc', gen_random_uuid()),
  'nfc|NULL',
  'record_scan con una etiqueta inexistente → tag_id NULL');
select is(
  pg_temp.scan('a0000000-0000-0000-0000-000000000001', '0000000a-0000-0000-0000-000000000000', 'qr', '7a000000-0000-0000-0000-000000000001'::uuid),
  'qr|NULL',
  'record_scan descarta la etiqueta si el canal no es nfc');
select is(
  pg_temp.scan('b0000000-0000-0000-0000-000000000001', '0000000b-0000-0000-0000-000000000000', 'nfc', '7a000000-0000-0000-0000-000000000001'::uuid),
  'nfc|NULL',
  'el escaneo con etiqueta ajena se registra igualmente con canal nfc');
select is((select count(*)::int from public.scan_events), 8,
  'los 8 eventos (2 directos + 6 de record_scan) están registrados');
select throws_ok($$ select public.record_scan(
    'a0000000-0000-0000-0000-000000000001', '0000000b-0000-0000-0000-000000000000', 'nfc',
    p_tag_id => '7a000000-0000-0000-0000-000000000001') $$,
  '23503', null, 'record_scan sigue rechazando org_id distinto al del enlace');
select pg_temp.logout();

select pg_temp.login('00000000-0000-0000-0000-0000000000a1');
select throws_ok($$ select public.record_scan(
    'a0000000-0000-0000-0000-000000000001', '0000000a-0000-0000-0000-000000000000', 'nfc') $$,
  '42501', null, 'authenticated sigue sin poder ejecutar record_scan');
select pg_temp.logout();

-- -----------------------------------------------------------------------------
-- Borrados: set null en eventos, cascade desde el enlace
-- -----------------------------------------------------------------------------
delete from public.nfc_tags where id = '7a000000-0000-0000-0000-000000000001';
select is((select count(*)::int from public.scan_events
           where tag_id = '7a000000-0000-0000-0000-000000000001'), 0,
  'borrar la etiqueta deja tag_id en NULL en sus eventos');
select is((select count(*)::int from public.scan_events
           where link_id = 'a0000000-0000-0000-0000-000000000001'), 7,
  'borrar la etiqueta conserva los escaneos');
select is((select count(*)::int from public.scan_events
           where link_id = 'a0000000-0000-0000-0000-000000000001' and channel = 'nfc'), 6,
  'los escaneos conservan el canal nfc');

delete from public.dynamic_links where id = 'a0000000-0000-0000-0000-000000000002';
select is((select count(*)::int from public.nfc_tags
           where link_id = 'a0000000-0000-0000-0000-000000000002'), 0,
  'borrar el enlace borra sus etiquetas (cascade)');
delete from public.organizations where id = '0000000b-0000-0000-0000-000000000000';
select is((select count(*)::int from public.nfc_tags
           where org_id = '0000000b-0000-0000-0000-000000000000'), 0,
  'borrar la org borra sus etiquetas (cascade vía el enlace)');

select * from finish();
rollback;
