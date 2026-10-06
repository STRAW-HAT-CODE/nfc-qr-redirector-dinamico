-- DQR-T022 · Tests de scan_events y record_scan (pgTAP).
-- Ejecutar: supabase test db. Todo corre dentro de BEGIN … ROLLBACK: no deja datos.
begin;

create extension if not exists pgtap with schema extensions;

select plan(68);

-- -----------------------------------------------------------------------------
-- Fixtures (como postgres)
-- -----------------------------------------------------------------------------
-- Org A: a1 owner · a2 viewer · Org B: b1 owner · pa platform admin · cc sin org
insert into auth.users (id, email, aud, role) values
  ('00000000-0000-0000-0000-0000000000a1', 'a1@test.local', 'authenticated', 'authenticated'),
  ('00000000-0000-0000-0000-0000000000a2', 'a2@test.local', 'authenticated', 'authenticated'),
  ('00000000-0000-0000-0000-0000000000b1', 'b1@test.local', 'authenticated', 'authenticated'),
  ('00000000-0000-0000-0000-0000000000ff', 'pa@test.local', 'authenticated', 'authenticated'),
  ('00000000-0000-0000-0000-0000000000cc', 'x@test.local',  'authenticated', 'authenticated');

insert into public.platform_admins (user_id) values ('00000000-0000-0000-0000-0000000000ff');

insert into public.organizations (id, name, slug) values
  ('0000000a-0000-0000-0000-000000000000', 'Org A', 'org-a'),
  ('0000000b-0000-0000-0000-000000000000', 'Org B', 'org-b');

insert into public.memberships (org_id, user_id, role) values
  ('0000000a-0000-0000-0000-000000000000', '00000000-0000-0000-0000-0000000000a1', 'owner'),
  ('0000000a-0000-0000-0000-000000000000', '00000000-0000-0000-0000-0000000000a2', 'viewer'),
  ('0000000b-0000-0000-0000-000000000000', '00000000-0000-0000-0000-0000000000b1', 'owner');

insert into public.dynamic_links (id, org_id, slug, name, destination_url) values
  ('a0000000-0000-0000-0000-000000000001', '0000000a-0000-0000-0000-000000000000',
   'ScanA01', 'Link A', 'https://a.example.com/'),
  ('a0000000-0000-0000-0000-000000000002', '0000000a-0000-0000-0000-000000000000',
   'ScanA02', 'Link A2', 'https://a.example.com/2'),
  ('b0000000-0000-0000-0000-000000000001', '0000000b-0000-0000-0000-000000000000',
   'ScanB01', 'Link B', 'https://b.example.com/');

-- 3 eventos en A (2 en el enlace 1, 1 en el enlace 2) y 2 en B.
insert into public.scan_events (link_id, org_id, channel) values
  ('a0000000-0000-0000-0000-000000000001', '0000000a-0000-0000-0000-000000000000', 'qr'),
  ('a0000000-0000-0000-0000-000000000001', '0000000a-0000-0000-0000-000000000000', 'direct'),
  ('a0000000-0000-0000-0000-000000000002', '0000000a-0000-0000-0000-000000000000', 'qr'),
  ('b0000000-0000-0000-0000-000000000001', '0000000b-0000-0000-0000-000000000000', 'qr'),
  ('b0000000-0000-0000-0000-000000000001', '0000000b-0000-0000-0000-000000000000', 'nfc');

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


-- -----------------------------------------------------------------------------
-- Esquema, índices y privilegios
-- -----------------------------------------------------------------------------
select has_table('public', 'scan_events', 'existe scan_events');
select ok((select relrowsecurity from pg_class where oid = 'public.scan_events'::regclass),
  'RLS habilitado en scan_events');
select col_type_is('public', 'scan_events', 'id', 'bigint', 'id es bigint');
select ok(
  (select attidentity = 'a' from pg_attribute
   where attrelid = 'public.scan_events'::regclass and attname = 'id'),
  'id es identity (generated always)');
select col_type_is('public', 'scan_events', 'channel', 'scan_channel', 'channel es el enum scan_channel');
select ok(enum_range(null::public.scan_channel) = array['qr', 'nfc', 'direct']::public.scan_channel[],
  'scan_channel = qr, nfc, direct');
select col_type_is('public', 'scan_events', 'country', 'character(2)', 'country es char(2)');
select col_type_is('public', 'scan_events', 'tag_id', 'uuid', 'tag_id es uuid');
select col_is_null('public', 'scan_events', 'tag_id', 'tag_id admite NULL');
select col_default_is('public', 'scan_events', 'occurred_at', 'now()', 'occurred_at default now()');
select col_default_is('public', 'scan_events', 'is_bot', 'false', 'is_bot default false');
select hasnt_column('public', 'scan_events', 'ip', 'no existe columna ip');

select has_index('public', 'scan_events', 'scan_events_link_occurred_idx',
  array['link_id', 'occurred_at'], 'índice (link_id, occurred_at)');
select has_index('public', 'scan_events', 'scan_events_org_occurred_idx',
  array['org_id', 'occurred_at'], 'índice (org_id, occurred_at)');
select ok(
  (select bool_and(pg_index_column_has_property(i::regclass, 2, 'desc'))
   from unnest(array['public.scan_events_link_occurred_idx',
                     'public.scan_events_org_occurred_idx']) as i),
  'occurred_at va en orden desc en ambos índices');
select is(
  (select am.amname::text from pg_class c join pg_am am on am.oid = c.relam
   where c.oid = 'public.scan_events_occurred_brin_idx'::regclass),
  'brin', 'índice BRIN en occurred_at');

select ok(exists (select 1 from pg_constraint
                  where conname = 'dynamic_links_id_org_key' and contype = 'u'
                    and conrelid = 'public.dynamic_links'::regclass),
  'dynamic_links tiene unique (id, org_id)');
select fk_ok('public', 'scan_events', array['link_id', 'org_id'],
             'public', 'dynamic_links', array['id', 'org_id'],
  'FK compuesta (link_id, org_id) → dynamic_links (id, org_id)');
select is(
  (select confdeltype::text from pg_constraint where conname = 'scan_events_link_org_fkey'),
  'c', 'la FK compuesta es on delete cascade');

select ok(
  not has_table_privilege('anon', 'public.scan_events', 'select,insert,update,delete,truncate'),
  'anon no tiene privilegios sobre scan_events');
select ok(has_table_privilege('authenticated', 'public.scan_events', 'select'),
  'authenticated puede leer (filtrado por RLS)');
select ok(
  not has_table_privilege('authenticated', 'public.scan_events', 'insert,update,delete,truncate'),
  'authenticated no puede insertar, actualizar ni borrar');
select ok(
  not has_sequence_privilege('anon', 'public.scan_events_id_seq', 'usage,select,update')
  and not has_sequence_privilege('authenticated', 'public.scan_events_id_seq', 'usage,select,update'),
  'anon/authenticated sin privilegios sobre la secuencia');
select ok(has_table_privilege('service_role', 'public.scan_events', 'select,insert,update,delete'),
  'service_role puede leer y escribir');

select ok(
  (select p.prosecdef and p.proconfig @> array['search_path=""']
   from pg_proc p
   where p.oid = 'public.record_scan(uuid, uuid, text, uuid, text, text, text, text, text, text, boolean)'::regprocedure),
  'record_scan: SECURITY DEFINER y search_path vacío');
select ok(not has_function_privilege('anon',
    'public.record_scan(uuid, uuid, text, uuid, text, text, text, text, text, text, boolean)', 'execute'),
  'anon no puede ejecutar record_scan');
select ok(not has_function_privilege('authenticated',
    'public.record_scan(uuid, uuid, text, uuid, text, text, text, text, text, text, boolean)', 'execute'),
  'authenticated no puede ejecutar record_scan');
select ok(has_function_privilege('service_role',
    'public.record_scan(uuid, uuid, text, uuid, text, text, text, text, text, text, boolean)', 'execute'),
  'service_role puede ejecutar record_scan');
select ok(
  not exists (select 1
              from pg_proc p, aclexplode(p.proacl) a
              where p.oid = 'public.record_scan(uuid, uuid, text, uuid, text, text, text, text, text, text, boolean)'::regprocedure
                and a.grantee = 0 and a.privilege_type = 'EXECUTE'),
  'PUBLIC no tiene EXECUTE sobre record_scan');

-- -----------------------------------------------------------------------------
-- CHECKs y coherencia de org (como postgres: también aplica a roles con BYPASSRLS)
-- -----------------------------------------------------------------------------
select throws_ok($$ insert into public.scan_events (link_id, org_id, channel)
  values ('a0000000-0000-0000-0000-000000000001', '0000000b-0000-0000-0000-000000000000', 'qr') $$,
  '23503', null, 'org_id distinto al del enlace rechazado (FK compuesta)');
select throws_ok($$ insert into public.scan_events (link_id, org_id, channel)
  values ('a0000000-0000-0000-0000-0000000000ee', '0000000a-0000-0000-0000-000000000000', 'qr') $$,
  '23503', null, 'enlace inexistente rechazado');
select throws_ok($$ insert into public.scan_events (link_id, org_id, channel)
  values ('a0000000-0000-0000-0000-000000000001', '0000000a-0000-0000-0000-000000000000', 'sms') $$,
  '22P02', null, 'canal fuera del enum rechazado');
select throws_ok($$ insert into public.scan_events (link_id, org_id, channel, ip_hash)
  values ('a0000000-0000-0000-0000-000000000001', '0000000a-0000-0000-0000-000000000000', 'qr', '203.0.113.7') $$,
  '23514', null, 'ip_hash con una IPv4 rechazado');
select throws_ok($$ insert into public.scan_events (link_id, org_id, channel, ip_hash)
  values ('a0000000-0000-0000-0000-000000000001', '0000000a-0000-0000-0000-000000000000', 'qr', '2001:db8::1') $$,
  '23514', null, 'ip_hash con una IPv6 rechazado');
select throws_ok($$ insert into public.scan_events (link_id, org_id, channel, tag_id)
  values ('a0000000-0000-0000-0000-000000000001', '0000000a-0000-0000-0000-000000000000', 'qr',
          '7a000000-0000-0000-0000-000000000001') $$,
  '23514', null, 'tag_id con canal distinto de nfc rechazado');
select throws_ok($$ insert into public.scan_events (link_id, org_id, channel, country)
  values ('a0000000-0000-0000-0000-000000000001', '0000000a-0000-0000-0000-000000000000', 'qr', 'mx') $$,
  '23514', null, 'country en minúsculas rechazado');
select throws_ok($$ insert into public.scan_events (link_id, org_id, channel, referer)
  values ('a0000000-0000-0000-0000-000000000001', '0000000a-0000-0000-0000-000000000000', 'qr',
          'https://r.example.com/' || repeat('x', 600)) $$,
  '23514', null, 'referer de más de 512 rechazado');
select throws_ok($$ insert into public.scan_events (link_id, org_id, channel, device)
  values ('a0000000-0000-0000-0000-000000000001', '0000000a-0000-0000-0000-000000000000', 'qr', repeat('d', 65)) $$,
  '23514', null, 'device de más de 64 rechazado');

-- dynamic_links.org_id es inmutable: la FK compuesta no se puede romper moviendo el enlace.
select throws_ok($$ update public.dynamic_links set org_id = '0000000b-0000-0000-0000-000000000000'
  where id = 'a0000000-0000-0000-0000-000000000001' $$,
  '42501', null, 'mover un enlace con eventos a otra org sigue prohibido');

-- -----------------------------------------------------------------------------
-- record_scan como service_role
-- -----------------------------------------------------------------------------
select pg_temp.as_role('service_role');

select ok(
  public.record_scan(
    'a0000000-0000-0000-0000-000000000001', '0000000a-0000-0000-0000-000000000000', 'nfc',
    p_tag_id  => '7a000000-0000-0000-0000-000000000001',
    p_country => ' mx ',
    p_device  => E'mobile\x01',
    p_os      => 'iOS 17',
    p_browser => repeat('b', 100),
    p_referer => 'https://ref.example.com/' || repeat('r', 1000),
    p_ip_hash => upper(repeat('ab', 32))
  ) > 0,
  'service_role registra un escaneo con record_scan');
select results_eq(
  $$ select channel::text, tag_id, country::text, device, os, char_length(browser),
            char_length(referer), ip_hash, is_bot
     from public.scan_events order by id desc limit 1 $$,
  $$ values ('nfc', '7a000000-0000-0000-0000-000000000001'::uuid, 'MX', 'mobile', 'iOS 17', 64,
             512, repeat('ab', 32), false) $$,
  'record_scan sanea: país en mayúsculas, sin controles, recorta browser/referer, ip_hash en minúsculas');
select ok(
  (select occurred_at = now() from public.scan_events order by id desc limit 1),
  'occurred_at = now() por defecto');

select lives_ok($$ select public.record_scan(
    'a0000000-0000-0000-0000-000000000001', '0000000a-0000-0000-0000-000000000000', 'qr',
    p_tag_id => '7a000000-0000-0000-0000-000000000001', p_country => 'XYZ',
    p_device => '   ', p_ip_hash => '', p_is_bot => null) $$,
  'record_scan con valores de cabecera inválidos no falla');
select results_eq(
  $$ select tag_id, country::text, device, ip_hash, is_bot
     from public.scan_events order by id desc limit 1 $$,
  $$ values (null::uuid, null::text, null::text, null::text, false) $$,
  'tag_id descartado fuera de nfc; país inválido, device vacío e ip_hash vacío → NULL; is_bot NULL → false');

select throws_ok($$ select public.record_scan(
    'a0000000-0000-0000-0000-000000000001', '0000000a-0000-0000-0000-000000000000', 'q') $$,
  '22023', 'record_scan: canal no válido', 'record_scan rechaza un canal no válido');
select throws_ok($$ select public.record_scan(
    'a0000000-0000-0000-0000-000000000001', '0000000a-0000-0000-0000-000000000000', null) $$,
  '22023', 'record_scan: canal no válido', 'record_scan rechaza canal NULL');
select throws_ok($$ select public.record_scan(
    'a0000000-0000-0000-0000-000000000001', '0000000a-0000-0000-0000-000000000000', 'qr',
    p_ip_hash => '203.0.113.7') $$,
  '22023', 'record_scan: ip_hash no válido (nunca la IP)', 'record_scan rechaza una IP en ip_hash');
select throws_ok($$ select public.record_scan(
    'a0000000-0000-0000-0000-000000000001', '0000000b-0000-0000-0000-000000000000', 'qr') $$,
  '23503', null, 'record_scan rechaza org_id distinto al del enlace');

select lives_ok($$ update public.scan_events set is_bot = true
  where link_id = 'a0000000-0000-0000-0000-000000000002' $$,
  'service_role puede actualizar (p. ej. marcar bots)');
select pg_temp.logout();

-- Fixture A queda con 5 eventos (3 + 2 de record_scan); B con 2.

-- -----------------------------------------------------------------------------
-- RLS de lectura: aislamiento A/B
-- -----------------------------------------------------------------------------
select pg_temp.login('00000000-0000-0000-0000-0000000000a2');  -- viewer A
select is((select count(*)::int from public.scan_events), 5, 'viewer de A ve los 5 eventos de A');
select is((select count(*)::int from public.scan_events
           where org_id = '0000000b-0000-0000-0000-000000000000'), 0, 'viewer de A no ve eventos de B');
select is((select count(*)::int from public.scan_events
           where link_id = 'b0000000-0000-0000-0000-000000000001'), 0,
  'viewer de A no ve eventos de B filtrando por link_id');
select throws_ok($$ insert into public.scan_events (link_id, org_id, channel)
  values ('a0000000-0000-0000-0000-000000000001', '0000000a-0000-0000-0000-000000000000', 'qr') $$,
  '42501', null, 'viewer no puede insertar');
select pg_temp.logout();

select pg_temp.login('00000000-0000-0000-0000-0000000000a1');  -- owner A
select throws_ok($$ insert into public.scan_events (link_id, org_id, channel)
  values ('a0000000-0000-0000-0000-000000000001', '0000000a-0000-0000-0000-000000000000', 'qr') $$,
  '42501', null, 'owner (authenticated) no puede insertar');
select throws_ok($$ update public.scan_events set is_bot = true $$,
  '42501', null, 'owner no puede actualizar eventos');
select throws_ok($$ delete from public.scan_events $$,
  '42501', null, 'owner no puede borrar eventos');
select throws_ok($$ select public.record_scan(
    'a0000000-0000-0000-0000-000000000001', '0000000a-0000-0000-0000-000000000000', 'qr') $$,
  '42501', null, 'authenticated no puede ejecutar record_scan');
select pg_temp.logout();

select pg_temp.login('00000000-0000-0000-0000-0000000000b1');  -- owner B
select is((select count(*)::int from public.scan_events), 2, 'owner de B ve solo los 2 eventos de B');
select is((select count(*)::int from public.scan_events
           where org_id = '0000000a-0000-0000-0000-000000000000'), 0, 'owner de B no ve eventos de A');
select pg_temp.logout();

select pg_temp.login('00000000-0000-0000-0000-0000000000cc');  -- sin org
select is((select count(*)::int from public.scan_events), 0, 'usuario sin org no ve eventos');
select pg_temp.logout();

select pg_temp.login('00000000-0000-0000-0000-0000000000ff');  -- platform admin
select is((select count(*)::int from public.scan_events), 7, 'platform admin ve todos los eventos');
select throws_ok($$ delete from public.scan_events $$,
  '42501', null, 'platform admin (authenticated) tampoco borra eventos');
select pg_temp.logout();

-- anon
select pg_temp.as_role('anon');
select throws_ok($$ select count(*) from public.scan_events $$,
  '42501', null, 'anon no puede leer scan_events');
select throws_ok($$ insert into public.scan_events (link_id, org_id, channel)
  values ('a0000000-0000-0000-0000-000000000001', '0000000a-0000-0000-0000-000000000000', 'qr') $$,
  '42501', null, 'anon no puede insertar');
select throws_ok($$ select public.record_scan(
    'a0000000-0000-0000-0000-000000000001', '0000000a-0000-0000-0000-000000000000', 'qr') $$,
  '42501', null, 'anon no puede ejecutar record_scan');
select pg_temp.logout();

-- -----------------------------------------------------------------------------
-- Cascada
-- -----------------------------------------------------------------------------
select pg_temp.as_role('service_role');
select lives_ok($$ delete from public.scan_events
  where link_id = 'a0000000-0000-0000-0000-000000000002' $$,
  'service_role puede borrar eventos');
select pg_temp.logout();

delete from public.dynamic_links where id = 'a0000000-0000-0000-0000-000000000001';
select is((select count(*)::int from public.scan_events
           where link_id = 'a0000000-0000-0000-0000-000000000001'), 0,
  'borrar el enlace borra sus eventos (cascade)');
delete from public.organizations where id = '0000000b-0000-0000-0000-000000000000';
select is((select count(*)::int from public.scan_events
           where org_id = '0000000b-0000-0000-0000-000000000000'), 0,
  'borrar la org borra sus eventos (cascade vía el enlace)');

select * from finish();
rollback;
