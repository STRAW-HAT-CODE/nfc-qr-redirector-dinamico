-- DQR-T018 · Tests de dynamic_links, historial y resolve_link (pgTAP).
-- Ejecutar: supabase test db. Todo corre dentro de BEGIN … ROLLBACK: no deja datos.
begin;

create extension if not exists pgtap with schema extensions;

select plan(212);

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
  and not has_column_privilege('authenticated', 'public.dynamic_links', 'created_by', 'insert')
  and not has_column_privilege('authenticated', 'public.dynamic_links', 'slug', 'insert'),
  'grants por columnas: slug/org_id no actualizables, slug/created_by no insertables');

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
select lives_ok($$ insert into public.dynamic_links (org_id, name, destination_url)
  values ('0000000a-0000-0000-0000-000000000000', 'Link A', 'https://a.example.com/') $$,
  'editor crea un enlace en su org (sin slug)');
select set_config('test.slug_a', (select slug from public.dynamic_links where name = 'Link A'), true);
select ok(current_setting('test.slug_a') ~ '^[0-9A-Za-z]{7}$', 'la BD genera un slug base62 de 7');
select is((select created_by from public.dynamic_links where slug = current_setting('test.slug_a')),
  '00000000-0000-0000-0000-0000000000e1'::uuid, 'created_by = auth.uid() por defecto');
select throws_ok($$ insert into public.dynamic_links (org_id, name, destination_url)
  values ('0000000b-0000-0000-0000-000000000000', 'x', 'https://a.example.com/') $$,
  '42501', null, 'editor no crea enlaces en otra org');
select throws_ok($$ insert into public.dynamic_links (org_id, name, destination_url, created_by)
  values ('0000000a-0000-0000-0000-000000000000', 'x', 'https://a.example.com/',
          '00000000-0000-0000-0000-0000000000a1') $$,
  '42501', null, 'editor no puede falsificar created_by');
select throws_ok($$ insert into public.dynamic_links (org_id, name, destination_url, status)
  values ('0000000a-0000-0000-0000-000000000000', 'x', 'https://a.example.com/', 'archived') $$,
  '42501', null, 'editor no crea enlaces ya archivados');
select lives_ok($$ update public.dynamic_links set destination_url = 'https://a.example.com/v2'
  where slug = current_setting('test.slug_a') $$, 'editor cambia el destino');
select is((select count(*)::int from public.link_destination_history h
           join public.dynamic_links l on l.id = h.link_id where l.slug = current_setting('test.slug_a')),
  1, 'cambiar el destino genera una fila de historial');
select ok((select h.old_url = 'https://a.example.com/' and h.new_url = 'https://a.example.com/v2'
                  and h.changed_by = '00000000-0000-0000-0000-0000000000e1'
                  and h.org_id = '0000000a-0000-0000-0000-000000000000'
                  and h.changed_at is not null
           from public.link_destination_history h
           join public.dynamic_links l on l.id = h.link_id where l.slug = current_setting('test.slug_a')),
  'historial: old_url, new_url, changed_by, org_id y changed_at correctos');
update public.dynamic_links set destination_url = 'https://a.example.com/v2', name = 'Link A2'
  where slug = current_setting('test.slug_a');
select is((select count(*)::int from public.link_destination_history h
           join public.dynamic_links l on l.id = h.link_id where l.slug = current_setting('test.slug_a')),
  1, 'sin cambio real de destino no hay historial nuevo');
select is((select name from public.dynamic_links where slug = current_setting('test.slug_a')), 'Link A2', 'editor edita el nombre');
select lives_ok($$ update public.dynamic_links set status = 'paused' where slug = current_setting('test.slug_a') $$,
  'editor pausa un enlace');
select throws_ok($$ update public.dynamic_links set status = 'archived' where slug = current_setting('test.slug_a') $$,
  '42501', null, 'editor no puede archivar');
select throws_ok($$ update public.dynamic_links set slug = 'Zzz9999' where slug = current_setting('test.slug_a') $$,
  '42501', null, 'editor no puede cambiar el slug');
select throws_ok($$ update public.dynamic_links set org_id = '0000000b-0000-0000-0000-000000000000'
  where slug = current_setting('test.slug_a') $$, '42501', null, 'editor no puede cambiar org_id');
select throws_ok($$ update public.dynamic_links set created_by = '00000000-0000-0000-0000-0000000000a1'
  where slug = current_setting('test.slug_a') $$, '42501', null, 'editor no puede cambiar created_by');
select throws_ok($$ insert into public.link_destination_history (link_id, org_id, old_url, new_url)
  select id, org_id, 'https://x', 'https://y' from public.dynamic_links where slug = current_setting('test.slug_a') $$,
  '42501', null, 'nadie inserta directo en el historial');
select throws_ok($$ update public.link_destination_history set new_url = 'https://evil.example.com' $$,
  '42501', null, 'nadie edita el historial');
select throws_ok($$ delete from public.link_destination_history $$,
  '42501', null, 'nadie borra el historial');
delete from public.dynamic_links where slug = current_setting('test.slug_a');
select pg_temp.logout();

select is((select status from public.dynamic_links where slug = current_setting('test.slug_a')),
  'paused'::public.link_status, 'el enlace sigue pausado (no archivado por editor)');
select ok(exists (select 1 from public.dynamic_links where slug = current_setting('test.slug_a')),
  'editor no puede borrar enlaces');

-- -----------------------------------------------------------------------------
-- Viewer: solo lee
-- -----------------------------------------------------------------------------
select pg_temp.login('00000000-0000-0000-0000-0000000000a2');
select is((select count(*)::int from public.dynamic_links), 1, 'viewer ve los enlaces de su org (y solo esos)');
select is((select count(*)::int from public.link_destination_history), 1, 'viewer lee el historial de su org');
select throws_ok($$ insert into public.dynamic_links (org_id, name, destination_url)
  values ('0000000a-0000-0000-0000-000000000000', 'x', 'https://a.example.com/') $$,
  '42501', null, 'viewer no crea enlaces');
update public.dynamic_links set name = 'viewer-hack', destination_url = 'https://evil.example.com/'
  where slug = current_setting('test.slug_a');
delete from public.dynamic_links where slug = current_setting('test.slug_a');
select pg_temp.logout();

select is((select name from public.dynamic_links where slug = current_setting('test.slug_a')), 'Link A2', 'viewer no edita enlaces');
select is((select destination_url from public.dynamic_links where slug = current_setting('test.slug_a')),
  'https://a.example.com/v2', 'viewer no cambia el destino');
select ok(exists (select 1 from public.dynamic_links where slug = current_setting('test.slug_a')), 'viewer no borra enlaces');

-- -----------------------------------------------------------------------------
-- Admin: archiva y borra
-- -----------------------------------------------------------------------------
select pg_temp.login('00000000-0000-0000-0000-0000000000a3');
select lives_ok($$ update public.dynamic_links set status = 'archived' where slug = current_setting('test.slug_a') $$,
  'admin archiva un enlace');
select pg_temp.logout();
select is((select status from public.dynamic_links where slug = current_setting('test.slug_a')),
  'archived'::public.link_status, 'el enlace quedó archivado');

select pg_temp.login('00000000-0000-0000-0000-0000000000e1');
update public.dynamic_links set status = 'active' where slug = current_setting('test.slug_a');
update public.dynamic_links set name = 'editor-archived' where slug = current_setting('test.slug_a');
select pg_temp.logout();
select ok((select status = 'archived' and name = 'Link A2' from public.dynamic_links where slug = current_setting('test.slug_a')),
  'editor no desarchiva ni edita un enlace archivado');

select pg_temp.login('00000000-0000-0000-0000-0000000000a3');
select lives_ok($$ update public.dynamic_links set status = 'active' where slug = current_setting('test.slug_a') $$,
  'admin desarchiva un enlace');
select lives_ok($$ insert into public.dynamic_links (org_id, name, destination_url)
  values ('0000000a-0000-0000-0000-000000000000', 'Borrar', 'https://a.example.com/del') $$,
  'admin crea un enlace');
select set_config('test.slug_del', (select slug from public.dynamic_links where name = 'Borrar'), true);
update public.dynamic_links set destination_url = 'https://a.example.com/del2' where slug = current_setting('test.slug_del');
select lives_ok($$ delete from public.dynamic_links where slug = current_setting('test.slug_del') $$, 'admin borra un enlace');
select pg_temp.logout();
select ok(not exists (select 1 from public.dynamic_links where slug = current_setting('test.slug_del')), 'el enlace fue borrado');
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
select ok((select created_by is null from public.dynamic_links where slug = current_setting('test.slug_a')),
  'borrar el usuario pone created_by a NULL');
select ok((select bool_and(h.changed_by is null) from public.link_destination_history h
           join public.dynamic_links l on l.id = h.link_id where l.slug = current_setting('test.slug_a')),
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
select throws_ok($$ select * from public.resolve_link('BBBBBB1') $$, '42501', null,
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

-- -----------------------------------------------------------------------------
-- H1 · Slug generado por la BD y nunca reasignado (private.slug_registry)
-- -----------------------------------------------------------------------------
select ok(exists (select 1 from private.slug_registry where slug = current_setting('test.slug_a')),
  'el slug generado queda registrado');
select ok(
  (select count(distinct s) = 500 and bool_and(s ~ '^[0-9A-Za-z]{7}$')
   from (select private.gen_slug() as s from generate_series(1, 500)) t),
  'gen_slug: 500 slugs base62 de 7, todos distintos');
select ok(not has_function_privilege('anon', 'private.gen_slug()', 'execute'),
  'anon no puede ejecutar gen_slug');

select pg_temp.login('00000000-0000-0000-0000-0000000000b1');
select throws_ok($$ insert into public.dynamic_links (org_id, slug, name, destination_url)
  values ('0000000b-0000-0000-0000-000000000000', current_setting('test.slug_del'), 'Robo', 'https://b.example.com/') $$,
  '42501', null, 'authenticated no puede elegir el slug (ni uno borrado de otra org)');
select throws_ok($$ select * from private.slug_registry $$, '42501', null,
  '(d) authenticated no lee private.slug_registry');
select pg_temp.logout();

select throws_ok($$ insert into public.dynamic_links (org_id, slug, name, destination_url)
  values ('0000000b-0000-0000-0000-000000000000', current_setting('test.slug_del'), 'Robo', 'https://b.example.com/') $$,
  '23505', 'dynamic_links: el slug ya fue usado y no se reasigna',
  '(a) un slug borrado de A no se reasigna a B');
select throws_ok($$ insert into public.dynamic_links (org_id, slug, name, destination_url)
  values ('0000000a-0000-0000-0000-000000000000', current_setting('test.slug_del'), 'Otra vez', 'https://a.example.com/') $$,
  '23505', 'dynamic_links: el slug ya fue usado y no se reasigna',
  '(b) la misma org tampoco reutiliza un slug borrado');
set local role service_role;
select throws_ok($$ insert into public.dynamic_links (org_id, slug, name, destination_url)
  values ('0000000b-0000-0000-0000-000000000000', current_setting('test.slug_del'), 'Servicio', 'https://b.example.com/') $$,
  '23505', 'dynamic_links: el slug ya fue usado y no se reasigna',
  '(c) service_role tampoco reasigna un slug borrado');
select throws_ok($$ insert into public.dynamic_links (org_id, slug, name, destination_url)
  values ('0000000b-0000-0000-0000-000000000000', 'BBBBBB1', 'Dup', 'https://b.example.com/') $$,
  '23505', null, '(e) un slug vivo duplicado sigue dando 23505');
select lives_ok($$ insert into public.dynamic_links (org_id, slug, name, destination_url)
  values ('0000000b-0000-0000-0000-000000000000', 'Seed001', 'Seed', 'https://b.example.com/seed') $$,
  'service_role puede fijar un slug nuevo (seed)');
reset role;

-- -----------------------------------------------------------------------------
-- H2 · Caracteres de control en URLs
-- -----------------------------------------------------------------------------
select throws_ok($$ insert into public.dynamic_links (org_id, name, destination_url)
  values ('0000000a-0000-0000-0000-000000000000', 'x', E'https://a.example.com/\x01') $$,
  '23514', null, 'destino con \x01 rechazado');
select throws_ok($$ insert into public.dynamic_links (org_id, name, destination_url)
  values ('0000000a-0000-0000-0000-000000000000', 'x', E'https://a.example.com/\x7f') $$,
  '23514', null, 'destino con \x7f rechazado');
select throws_ok($$ insert into public.dynamic_links (org_id, name, destination_url, fallback_url)
  values ('0000000a-0000-0000-0000-000000000000', 'x', 'https://a.example.com/', E'https://f.example.com/\x01') $$,
  '23514', null, 'fallback con \x01 rechazado');
select throws_ok($$ insert into public.dynamic_links (org_id, name, destination_url, fallback_url)
  values ('0000000a-0000-0000-0000-000000000000', 'x', 'https://a.example.com/', E'https://f.example.com/\x7f') $$,
  '23514', null, 'fallback con \x7f rechazado');

-- -----------------------------------------------------------------------------
-- H3b · private.is_safe_url (mismos casos que apps/api/tests/test_url_policy.py)
-- -----------------------------------------------------------------------------
select ok(private.is_safe_url(u), 'is_safe_url acepta ' || u)
from unnest(array[
  'https://example.com',
  'http://example.com/a/b?x=1#f',
  'HTTPS://Example.COM/Path',
  'HtTp://example.com',
  'https://example.com.',
  'https://example.com:8443/x',
  'https://example.com:/x',
  'https://8.8.8.8/',
  'https://[2606:4700:4700::1111]/',
  'https://xn--mnchen-3ya.de/straße',
  'https://sub.example.com',
  'https://notmonky.dev'
]) as u;

-- Esquema no permitido
select ok(not private.is_safe_url(u), 'is_safe_url rechaza (esquema) ' || u)
from unnest(array[
  'javascript:alert(1)',
  'JAVASCRIPT:alert(1)',
  'data:text/html,<script>alert(1)</script>',
  'ftp://example.com',
  'file:///etc/passwd',
  'mailto:a@b.com',
  '//example.com',
  'example.com',
  'gopher://example.com',
  'ws://example.com'
]) as u;

-- Credenciales
select ok(not private.is_safe_url(u), 'is_safe_url rechaza (credenciales) ' || u)
from unnest(array[
  'http://user@evil.com',
  'http://user:pass@evil.com',
  'https://:pass@evil.com',
  'https://example.com@evil.com',
  'https://evil.com\@example.com',
  'http://user:pass@example.com'
]) as u;

-- Hosts locales / privados (incluye IPv4 legacy e IPv6)
select ok(not private.is_safe_url(u), 'is_safe_url rechaza (privado) ' || u)
from unnest(array[
  'http://localhost',
  'http://LOCALHOST:3000/x',
  'http://localhost./',
  'http://foo.localhost',
  'http://127.0.0.1',
  'http://127.1',
  'http://127.0.1',
  'http://2130706433',
  'http://0x7f000001',
  'http://0X7F.0.0.1',
  'http://0177.0.0.1',
  'http://017700000001',
  'http://0x7f.1',
  'http://0',
  'http://0.0.0.0',
  'http://10.0.0.1',
  'http://10.1',
  'http://172.16.0.1',
  'http://172.31.255.255',
  'http://192.168.1.1',
  'http://169.254.169.254',
  'http://100.64.0.1',
  'http://224.0.0.1',
  'http://255.255.255.255',
  'http://[::1]',
  'http://[::1]:8080/',
  'http://[::]',
  'http://[::ffff:127.0.0.1]',
  'http://[::ffff:7f00:1]',
  'http://[::ffff:10.0.0.1]',
  'http://[fe80::1]',
  'http://[fc00::1]',
  'http://[fd12:3456::1]',
  'http://[2002:7f00:1::]',
  'http://[ff02::1]',
  'http://printer.local',
  'http://db.internal',
  'http://a.b.INTERNAL',
  'http://intranet',
  'http://127.0.0.1.'
]) as u;

-- Inválidas
select ok(not private.is_safe_url(u), 'is_safe_url rechaza (inválida) ' || quote_literal(u))
from unnest(array[
  'http://',
  'https://',
  'http:///path',
  'http://:80',
  'http://example.com:99999',
  'http://example.com:0',
  'http://example.com:abc',
  'http://256.256.256.256',
  'http://1.2.3.4.5',
  'http://089.1.1.1',
  'http://[::1',
  'http://[zzz]',
  'http://[fe80::1%25eth0]',
  'http://exa mple.com',
  'http://example.com/a b',
  'http://a..b',
  'http://%6c%6f%63%61%6c%68%6f%73%74.com',
  'https://münchen.de',
  '',
  '   ',
  E'\t',
  'https://example.com/' || repeat('a', 2029)
]) as u;
select ok(private.is_safe_url('https://example.com/' || repeat('a', 2028)),
  'is_safe_url acepta exactamente 2048 caracteres');
select ok(not private.is_safe_url(null), 'is_safe_url(NULL) = false');

-- El CHECK actúa sobre escrituras reales de authenticated (bypass de la API).
select pg_temp.login('00000000-0000-0000-0000-0000000000a1');
select throws_ok($$ insert into public.dynamic_links (org_id, name, destination_url)
  values ('0000000a-0000-0000-0000-000000000000', 'ssrf', 'http://169.254.169.254/latest/meta-data') $$,
  '23514', null, 'CHECK: destino a metadata (link-local) rechazado');
select throws_ok($$ insert into public.dynamic_links (org_id, name, destination_url)
  values ('0000000a-0000-0000-0000-000000000000', 'cred', 'https://good.com@evil.com/') $$,
  '23514', null, 'CHECK: destino con credenciales rechazado');
select throws_ok($$ insert into public.dynamic_links (org_id, name, destination_url, fallback_url)
  values ('0000000a-0000-0000-0000-000000000000', 'fb', 'https://a.example.com/', 'http://10.0.0.1/') $$,
  '23514', null, 'CHECK: fallback a IP privada rechazado');
select throws_ok($$ update public.dynamic_links set destination_url = 'https://localhost/'
  where slug = current_setting('test.slug_a') $$,
  '23514', null, 'CHECK: cambiar el destino a localhost rechazado');

-- -----------------------------------------------------------------------------
-- H3c · Blocklist de dominios (private.blocked_domains)
-- -----------------------------------------------------------------------------
select throws_ok($$ select * from private.blocked_domains $$, '42501', null,
  'authenticated no lee private.blocked_domains');
select throws_ok($$ insert into private.blocked_domains (domain) values ('example.org') $$, '42501', null,
  'authenticated no escribe en private.blocked_domains');
select pg_temp.logout();

insert into private.blocked_domains (domain) values ('evil.com'), ('xn--mnchen-3ya.de');
select throws_ok($$ insert into private.blocked_domains (domain) values ('EVIL.org') $$, '23514', null,
  'blocked_domains exige minúsculas');
select throws_ok($$ insert into private.blocked_domains (domain) values ('.evil.org.') $$, '23514', null,
  'blocked_domains rechaza puntos extremos');

select pg_temp.login('00000000-0000-0000-0000-0000000000a1');
select throws_ok(
  format($f$ insert into public.dynamic_links (org_id, name, destination_url)
             values ('0000000a-0000-0000-0000-000000000000', 'blk', %L) $f$, u),
  '23514', 'dynamic_links: el dominio de destino no está permitido', 'blocklist rechaza ' || u)
from unnest(array[
  'https://evil.com',
  'https://EVIL.com/x',
  'https://www.evil.com',
  'https://a.b.evil.com/x',
  'https://evil.com.',
  'https://xn--mnchen-3ya.de'
]) as u;
select lives_ok(
  format($f$ insert into public.dynamic_links (org_id, name, destination_url)
             values ('0000000a-0000-0000-0000-000000000000', 'ok-blk', %L) $f$, u),
  'blocklist sin falso positivo: ' || u)
from unnest(array['https://notevil.com', 'https://evil.com.mx', 'https://evil.co']) as u;
select throws_ok($$ insert into public.dynamic_links (org_id, name, destination_url, fallback_url)
  values ('0000000a-0000-0000-0000-000000000000', 'blk-fb', 'https://a.example.com/', 'https://www.evil.com/') $$,
  '23514', 'dynamic_links: el dominio del fallback no está permitido', 'blocklist aplica al fallback');
select throws_ok($$ update public.dynamic_links set destination_url = 'https://login.evil.com/'
  where slug = current_setting('test.slug_a') $$,
  '23514', 'dynamic_links: el dominio de destino no está permitido', 'blocklist aplica al cambiar el destino');
select pg_temp.logout();

-- Bloquear un dominio después no impide editar otros campos del enlace.
insert into private.blocked_domains (domain) values ('notevil.com');
select pg_temp.login('00000000-0000-0000-0000-0000000000a1');
select lives_ok($$ update public.dynamic_links set name = 'renombrado'
  where destination_url = 'https://notevil.com' $$,
  'editar el nombre de un enlace con dominio bloqueado después sigue funcionando');
select pg_temp.logout();

select * from finish();
rollback;
