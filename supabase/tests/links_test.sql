-- DQR-T018 · Tests de dynamic_links, historial y resolve_link (pgTAP).
-- Ejecutar: supabase test db. Todo corre dentro de BEGIN … ROLLBACK: no deja datos.
begin;

create extension if not exists pgtap with schema extensions;

select plan(85);

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

-- Enlace de Org B con un cambio de destino ya registrado (como servicio).
insert into public.dynamic_links (id, org_id, slug, name, destination_url, created_by) values
  ('b0000000-0000-0000-0000-000000000001', '0000000b-0000-0000-0000-000000000000',
   'BBBBBB1', 'Link B', 'https://b.example.com/', '00000000-0000-0000-0000-0000000000b1');
update public.dynamic_links set destination_url = 'https://b.example.com/v2'
  where id = 'b0000000-0000-0000-0000-000000000001';

-- Simula una petición con el JWT de un usuario.
create function pg_temp.login(p_uid uuid) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub', p_uid, 'role', 'authenticated')::text, true);
  execute 'set local role authenticated';
end $$;

create function pg_temp.logout() returns void language plpgsql as $$
begin
  execute 'reset role';
  perform set_config('request.jwt.claims', '', true);
end $$;

-- -----------------------------------------------------------------------------
-- Esquema, índices y privilegios
-- -----------------------------------------------------------------------------
select has_table('public', 'dynamic_links', 'existe dynamic_links');
select has_table('public', 'link_destination_history', 'existe link_destination_history');
select ok(
  (select bool_and(c.relrowsecurity) from pg_class c
   where c.oid in ('public.dynamic_links'::regclass, 'public.link_destination_history'::regclass)),
  'RLS habilitado en dynamic_links y link_destination_history');
select ok(exists (select 1 from pg_constraint
                  where conname = 'dynamic_links_slug_key' and contype = 'u'),
  'slug tiene constraint unique');
select has_index('public', 'dynamic_links', 'dynamic_links_org_created_idx', 'índice (org_id, created_at desc)');
select has_index('public', 'dynamic_links', 'dynamic_links_org_status_idx', 'índice (org_id, status)');
select has_index('public', 'link_destination_history', 'link_destination_history_link_idx',
  'índice por link_id en el historial');
select ok(
  (select p.prosecdef and p.provolatile = 's' and p.proconfig @> array['search_path=""']
   from pg_proc p where p.oid = 'public.resolve_link(text)'::regprocedure),
  'resolve_link: SECURITY DEFINER, STABLE y search_path vacío');
select ok(not has_function_privilege('anon', 'public.resolve_link(text)', 'execute'),
  'anon no puede ejecutar resolve_link');
select ok(not has_function_privilege('authenticated', 'public.resolve_link(text)', 'execute'),
  'authenticated no puede ejecutar resolve_link');
select ok(has_function_privilege('service_role', 'public.resolve_link(text)', 'execute'),
  'service_role puede ejecutar resolve_link');
select ok(
  not has_table_privilege('anon', 'public.dynamic_links', 'select,insert,update,delete')
  and not has_table_privilege('anon', 'public.link_destination_history', 'select,insert,update,delete'),
  'anon no tiene privilegios sobre las tablas de enlaces');
select ok(
  not has_table_privilege('authenticated', 'public.link_destination_history', 'insert,update,delete'),
  'authenticated no puede escribir el historial');
select ok(
  not has_column_privilege('authenticated', 'public.dynamic_links', 'slug', 'update')
  and not has_column_privilege('authenticated', 'public.dynamic_links', 'org_id', 'update')
  and not has_column_privilege('authenticated', 'public.dynamic_links', 'created_by', 'insert'),
  'grants por columnas: slug/org_id no actualizables, created_by no insertable');

-- -----------------------------------------------------------------------------
-- CHECKs (como postgres)
-- -----------------------------------------------------------------------------
select throws_ok($$ insert into public.dynamic_links (org_id, slug, name, destination_url)
  values ('0000000a-0000-0000-0000-000000000000', 'abc123', 'x', 'https://a.example.com') $$,
  '23514', null, 'slug de 6 caracteres rechazado');
select throws_ok($$ insert into public.dynamic_links (org_id, slug, name, destination_url)
  values ('0000000a-0000-0000-0000-000000000000', 'abc12345', 'x', 'https://a.example.com') $$,
  '23514', null, 'slug de 8 caracteres rechazado');
select throws_ok($$ insert into public.dynamic_links (org_id, slug, name, destination_url)
  values ('0000000a-0000-0000-0000-000000000000', 'abc-123', 'x', 'https://a.example.com') $$,
  '23514', null, 'slug con guion rechazado');
select throws_ok($$ insert into public.dynamic_links (org_id, slug, name, destination_url)
  values ('0000000a-0000-0000-0000-000000000000', 'abcñ123', 'x', 'https://a.example.com') $$,
  '23514', null, 'slug no ASCII rechazado');
select throws_ok($$ insert into public.dynamic_links (org_id, slug, name, destination_url)
  values ('0000000a-0000-0000-0000-000000000000', 'BBBBBB1', 'x', 'https://a.example.com') $$,
  '23505', null, 'slug duplicado rechazado (unique global)');
select throws_ok($$ insert into public.dynamic_links (org_id, slug, name, destination_url)
  values ('0000000a-0000-0000-0000-000000000000', 'Chk0001', 'x', 'ftp://a.example.com') $$,
  '23514', null, 'destination_url ftp:// rechazado');
select throws_ok($$ insert into public.dynamic_links (org_id, slug, name, destination_url)
  values ('0000000a-0000-0000-0000-000000000000', 'Chk0002', 'x', 'javascript:alert(1)') $$,
  '23514', null, 'destination_url javascript: rechazado');
select throws_ok($$ insert into public.dynamic_links (org_id, slug, name, destination_url)
  values ('0000000a-0000-0000-0000-000000000000', 'Chk0003', 'x', 'https://') $$,
  '23514', null, 'destination_url sin host rechazado');
select throws_ok($$ insert into public.dynamic_links (org_id, slug, name, destination_url)
  values ('0000000a-0000-0000-0000-000000000000', 'Chk0004', 'x', 'https://a.example.com/a b') $$,
  '23514', null, 'destination_url con espacios rechazado');
select throws_ok($$ insert into public.dynamic_links (org_id, slug, name, destination_url, fallback_url)
  values ('0000000a-0000-0000-0000-000000000000', 'Chk0005', 'x', 'https://a.example.com',
          'mailto:a@example.com') $$,
  '23514', null, 'fallback_url mailto: rechazado');
select throws_ok($$ insert into public.dynamic_links (org_id, slug, name, destination_url, starts_at, expires_at)
  values ('0000000a-0000-0000-0000-000000000000', 'Chk0006', 'x', 'https://a.example.com',
          '2026-02-01', '2026-01-01') $$,
  '23514', null, 'starts_at posterior a expires_at rechazado');
select throws_ok($$ insert into public.dynamic_links (org_id, slug, name, destination_url, starts_at, expires_at)
  values ('0000000a-0000-0000-0000-000000000000', 'Chk0007', 'x', 'https://a.example.com',
          '2026-01-01', '2026-01-01') $$,
  '23514', null, 'starts_at igual a expires_at rechazado');
select throws_ok($$ insert into public.dynamic_links (org_id, slug, name, destination_url)
  values ('0000000a-0000-0000-0000-000000000000', 'Chk0008', '   ', 'https://a.example.com') $$,
  '23514', null, 'name vacío rechazado');
select lives_ok($$ insert into public.dynamic_links (org_id, slug, name, destination_url, fallback_url, starts_at, expires_at)
  values ('0000000a-0000-0000-0000-000000000000', 'Chk0009', 'ok', 'HTTPS://Example.com:8443/p?q=1#f',
          'http://fallback.example.com', '2026-01-01', '2026-02-01') $$,
  'URLs http/https válidas y vigencia correcta aceptadas');
delete from public.dynamic_links where slug = 'Chk0009';

-- -----------------------------------------------------------------------------
-- Editor: crea y edita
-- -----------------------------------------------------------------------------
select pg_temp.login('00000000-0000-0000-0000-0000000000e1');
select lives_ok($$ insert into public.dynamic_links (org_id, slug, name, destination_url)
  values ('0000000a-0000-0000-0000-000000000000', 'Abc1234', 'Link A', 'https://a.example.com/') $$,
  'editor crea un enlace en su org');
select is((select created_by from public.dynamic_links where slug = 'Abc1234'),
  '00000000-0000-0000-0000-0000000000e1'::uuid, 'created_by = auth.uid() por defecto');
select throws_ok($$ insert into public.dynamic_links (org_id, slug, name, destination_url)
  values ('0000000b-0000-0000-0000-000000000000', 'Abc9999', 'x', 'https://a.example.com/') $$,
  '42501', null, 'editor no crea enlaces en otra org');
select throws_ok($$ insert into public.dynamic_links (org_id, slug, name, destination_url, created_by)
  values ('0000000a-0000-0000-0000-000000000000', 'Abc9998', 'x', 'https://a.example.com/',
          '00000000-0000-0000-0000-0000000000a1') $$,
  '42501', null, 'editor no puede falsificar created_by');
select throws_ok($$ insert into public.dynamic_links (org_id, slug, name, destination_url, status)
  values ('0000000a-0000-0000-0000-000000000000', 'Abc9997', 'x', 'https://a.example.com/', 'archived') $$,
  '42501', null, 'editor no crea enlaces ya archivados');
select lives_ok($$ update public.dynamic_links set destination_url = 'https://a.example.com/v2'
  where slug = 'Abc1234' $$, 'editor cambia el destino');
select is((select count(*)::int from public.link_destination_history h
           join public.dynamic_links l on l.id = h.link_id where l.slug = 'Abc1234'),
  1, 'cambiar el destino genera una fila de historial');
select ok((select h.old_url = 'https://a.example.com/' and h.new_url = 'https://a.example.com/v2'
                  and h.changed_by = '00000000-0000-0000-0000-0000000000e1'
                  and h.org_id = '0000000a-0000-0000-0000-000000000000'
                  and h.changed_at is not null
           from public.link_destination_history h
           join public.dynamic_links l on l.id = h.link_id where l.slug = 'Abc1234'),
  'historial: old_url, new_url, changed_by, org_id y changed_at correctos');
update public.dynamic_links set destination_url = 'https://a.example.com/v2', name = 'Link A2'
  where slug = 'Abc1234';
select is((select count(*)::int from public.link_destination_history h
           join public.dynamic_links l on l.id = h.link_id where l.slug = 'Abc1234'),
  1, 'sin cambio real de destino no hay historial nuevo');
select is((select name from public.dynamic_links where slug = 'Abc1234'), 'Link A2', 'editor edita el nombre');
select lives_ok($$ update public.dynamic_links set status = 'paused' where slug = 'Abc1234' $$,
  'editor pausa un enlace');
select throws_ok($$ update public.dynamic_links set status = 'archived' where slug = 'Abc1234' $$,
  '42501', null, 'editor no puede archivar');
select throws_ok($$ update public.dynamic_links set slug = 'Zzz9999' where slug = 'Abc1234' $$,
  '42501', null, 'editor no puede cambiar el slug');
select throws_ok($$ update public.dynamic_links set org_id = '0000000b-0000-0000-0000-000000000000'
  where slug = 'Abc1234' $$, '42501', null, 'editor no puede cambiar org_id');
select throws_ok($$ update public.dynamic_links set created_by = '00000000-0000-0000-0000-0000000000a1'
  where slug = 'Abc1234' $$, '42501', null, 'editor no puede cambiar created_by');
select throws_ok($$ insert into public.link_destination_history (link_id, org_id, old_url, new_url)
  select id, org_id, 'https://x', 'https://y' from public.dynamic_links where slug = 'Abc1234' $$,
  '42501', null, 'nadie inserta directo en el historial');
select throws_ok($$ update public.link_destination_history set new_url = 'https://evil.example.com' $$,
  '42501', null, 'nadie edita el historial');
select throws_ok($$ delete from public.link_destination_history $$,
  '42501', null, 'nadie borra el historial');
delete from public.dynamic_links where slug = 'Abc1234';
select pg_temp.logout();

select is((select status from public.dynamic_links where slug = 'Abc1234'),
  'paused'::public.link_status, 'el enlace sigue pausado (no archivado por editor)');
select ok(exists (select 1 from public.dynamic_links where slug = 'Abc1234'),
  'editor no puede borrar enlaces');

-- -----------------------------------------------------------------------------
-- Viewer: solo lee
-- -----------------------------------------------------------------------------
select pg_temp.login('00000000-0000-0000-0000-0000000000a2');
select is((select count(*)::int from public.dynamic_links), 1, 'viewer ve los enlaces de su org (y solo esos)');
select is((select count(*)::int from public.link_destination_history), 1, 'viewer lee el historial de su org');
select throws_ok($$ insert into public.dynamic_links (org_id, slug, name, destination_url)
  values ('0000000a-0000-0000-0000-000000000000', 'Vwr0001', 'x', 'https://a.example.com/') $$,
  '42501', null, 'viewer no crea enlaces');
update public.dynamic_links set name = 'viewer-hack', destination_url = 'https://evil.example.com/'
  where slug = 'Abc1234';
delete from public.dynamic_links where slug = 'Abc1234';
select pg_temp.logout();

select is((select name from public.dynamic_links where slug = 'Abc1234'), 'Link A2', 'viewer no edita enlaces');
select is((select destination_url from public.dynamic_links where slug = 'Abc1234'),
  'https://a.example.com/v2', 'viewer no cambia el destino');
select ok(exists (select 1 from public.dynamic_links where slug = 'Abc1234'), 'viewer no borra enlaces');

-- -----------------------------------------------------------------------------
-- Admin: archiva y borra
-- -----------------------------------------------------------------------------
select pg_temp.login('00000000-0000-0000-0000-0000000000a3');
select lives_ok($$ update public.dynamic_links set status = 'archived' where slug = 'Abc1234' $$,
  'admin archiva un enlace');
select pg_temp.logout();
select is((select status from public.dynamic_links where slug = 'Abc1234'),
  'archived'::public.link_status, 'el enlace quedó archivado');

select pg_temp.login('00000000-0000-0000-0000-0000000000e1');
update public.dynamic_links set status = 'active' where slug = 'Abc1234';
update public.dynamic_links set name = 'editor-archived' where slug = 'Abc1234';
select pg_temp.logout();
select ok((select status = 'archived' and name = 'Link A2' from public.dynamic_links where slug = 'Abc1234'),
  'editor no desarchiva ni edita un enlace archivado');

select pg_temp.login('00000000-0000-0000-0000-0000000000a3');
select lives_ok($$ update public.dynamic_links set status = 'active' where slug = 'Abc1234' $$,
  'admin desarchiva un enlace');
select lives_ok($$ insert into public.dynamic_links (org_id, slug, name, destination_url)
  values ('0000000a-0000-0000-0000-000000000000', 'Del0001', 'Borrar', 'https://a.example.com/del') $$,
  'admin crea un enlace');
update public.dynamic_links set destination_url = 'https://a.example.com/del2' where slug = 'Del0001';
select lives_ok($$ delete from public.dynamic_links where slug = 'Del0001' $$, 'admin borra un enlace');
select pg_temp.logout();
select ok(not exists (select 1 from public.dynamic_links where slug = 'Del0001'), 'el enlace fue borrado');
select is((select count(*)::int from public.link_destination_history
           where new_url = 'https://a.example.com/del2'),
  0, 'el historial del enlace borrado se elimina en cascada');

-- -----------------------------------------------------------------------------
-- Aislamiento org A / org B
-- -----------------------------------------------------------------------------
select pg_temp.login('00000000-0000-0000-0000-0000000000a1');
select is((select count(*)::int from public.dynamic_links where org_id = '0000000b-0000-0000-0000-000000000000'),
  0, 'owner de A no ve enlaces de B');
select is((select count(*)::int from public.dynamic_links where slug = 'BBBBBB1'),
  0, 'owner de A no encuentra el slug de B');
select is((select count(*)::int from public.link_destination_history
           where org_id = '0000000b-0000-0000-0000-000000000000'),
  0, 'owner de A no ve el historial de B');
update public.dynamic_links set name = 'pwned', destination_url = 'https://evil.example.com/'
  where slug = 'BBBBBB1';
delete from public.dynamic_links where slug = 'BBBBBB1';
select pg_temp.logout();
select ok((select name = 'Link B' and destination_url = 'https://b.example.com/v2'
           from public.dynamic_links where slug = 'BBBBBB1'),
  'enlace de B intacto tras update/delete de A');

select pg_temp.login('00000000-0000-0000-0000-0000000000b1');
select is((select count(*)::int from public.dynamic_links), 1, 'owner de B solo ve su enlace');
select is((select count(*)::int from public.link_destination_history), 1, 'owner de B solo ve su historial');
select pg_temp.logout();

select pg_temp.login('00000000-0000-0000-0000-0000000000cc');
select is((select count(*)::int from public.dynamic_links), 0, 'usuario sin org no ve enlaces');
select is((select count(*)::int from public.link_destination_history), 0, 'usuario sin org no ve historial');
select pg_temp.logout();

-- -----------------------------------------------------------------------------
-- Platform admin
-- -----------------------------------------------------------------------------
select pg_temp.login('00000000-0000-0000-0000-0000000000ff');
select is((select count(*)::int from public.dynamic_links), 2, 'platform admin ve todos los enlaces');
select lives_ok($$ update public.dynamic_links set status = 'archived' where slug = 'BBBBBB1' $$,
  'platform admin archiva un enlace de cualquier org');
select pg_temp.logout();
select is((select status from public.dynamic_links where slug = 'BBBBBB1'),
  'archived'::public.link_status, 'el enlace de B quedó archivado por platform admin');

-- -----------------------------------------------------------------------------
-- Inmutables y updated_at también para servicio (postgres / service_role)
-- -----------------------------------------------------------------------------
select throws_ok($$ update public.dynamic_links set slug = 'Zzz9999' where slug = 'BBBBBB1' $$,
  '42501', 'dynamic_links: id, slug, org_id y created_at son inmutables',
  'slug inmutable incluso para postgres');
set local role service_role;
select throws_ok($$ update public.dynamic_links set org_id = '0000000a-0000-0000-0000-000000000000'
  where slug = 'BBBBBB1' $$,
  '42501', 'dynamic_links: id, slug, org_id y created_at son inmutables',
  'org_id inmutable incluso para service_role');
select throws_ok($$ update public.dynamic_links set created_by = '00000000-0000-0000-0000-0000000000a1'
  where slug = 'BBBBBB1' $$,
  '42501', 'dynamic_links: created_by es inmutable', 'created_by inmutable incluso para service_role');
reset role;

update public.dynamic_links set name = 'Link B2', updated_at = '2000-01-01' where slug = 'BBBBBB1';
select ok((select updated_at > '2000-01-01' from public.dynamic_links where slug = 'BBBBBB1'),
  'updated_at lo fija el trigger');

-- Borrar el usuario en Auth deja created_by / changed_by en NULL (única excepción).
delete from auth.users where id = '00000000-0000-0000-0000-0000000000e1';
select ok((select created_by is null from public.dynamic_links where slug = 'Abc1234'),
  'borrar el usuario pone created_by a NULL');
select ok((select bool_and(h.changed_by is null) from public.link_destination_history h
           join public.dynamic_links l on l.id = h.link_id where l.slug = 'Abc1234'),
  'borrar el usuario pone changed_by a NULL');

-- -----------------------------------------------------------------------------
-- anon y resolve_link
-- -----------------------------------------------------------------------------
set local role anon;
select throws_ok($$ select * from public.dynamic_links $$, '42501', null, 'anon no lee dynamic_links');
select throws_ok($$ select * from public.link_destination_history $$, '42501', null,
  'anon no lee link_destination_history');
select throws_ok($$ select * from public.resolve_link('BBBBBB1') $$, '42501', null,
  'anon no ejecuta resolve_link');
reset role;

select pg_temp.login('00000000-0000-0000-0000-0000000000a1');
select throws_ok($$ select * from public.resolve_link('Abc1234') $$, '42501', null,
  'authenticated no ejecuta resolve_link');
select pg_temp.logout();

update public.organizations set status = 'suspended' where id = '0000000b-0000-0000-0000-000000000000';
set local role service_role;
select results_eq(
  $$ select id, org_id, destination_url, fallback_url, status, starts_at, expires_at, org_status
     from public.resolve_link('BBBBBB1') $$,
  $$ values ('b0000000-0000-0000-0000-000000000001'::uuid, '0000000b-0000-0000-0000-000000000000'::uuid,
             'https://b.example.com/v2'::text, null::text, 'archived'::public.link_status,
             null::timestamptz, null::timestamptz, 'suspended'::public.org_status) $$,
  'service_role resuelve el slug con estado del enlace y de la org');
select is((select count(*)::int from public.resolve_link('NoExist')), 0,
  'resolve_link de un slug inexistente no devuelve filas');
reset role;

select * from finish();
rollback;
