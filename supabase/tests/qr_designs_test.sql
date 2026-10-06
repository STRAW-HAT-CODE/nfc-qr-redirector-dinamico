-- DQR-T031 · Tests de qr_designs y del bucket privado logos (pgTAP).
-- Ejecutar: supabase test db. Todo corre dentro de BEGIN … ROLLBACK: no deja datos.
begin;

create extension if not exists pgtap with schema extensions;

select plan(100);

-- -----------------------------------------------------------------------------
-- Fixtures (como postgres)
-- -----------------------------------------------------------------------------
-- Org A: a1 owner · a2 viewer · a3 editor · a4 admin · Org B: b1 owner
-- pa platform admin · cc sin org
insert into auth.users (id, email, aud, role) values
  ('00000000-0000-0000-0000-0000000000a1', 'a1@test.local', 'authenticated', 'authenticated'),
  ('00000000-0000-0000-0000-0000000000a2', 'a2@test.local', 'authenticated', 'authenticated'),
  ('00000000-0000-0000-0000-0000000000a3', 'a3@test.local', 'authenticated', 'authenticated'),
  ('00000000-0000-0000-0000-0000000000a4', 'a4@test.local', 'authenticated', 'authenticated'),
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
  ('0000000a-0000-0000-0000-000000000000', '00000000-0000-0000-0000-0000000000a3', 'editor'),
  ('0000000a-0000-0000-0000-000000000000', '00000000-0000-0000-0000-0000000000a4', 'admin'),
  ('0000000b-0000-0000-0000-000000000000', '00000000-0000-0000-0000-0000000000b1', 'owner');

insert into public.dynamic_links (id, org_id, slug, name, destination_url) values
  ('a0000000-0000-0000-0000-000000000001', '0000000a-0000-0000-0000-000000000000',
   'QrdsA01', 'Link A1', 'https://a.example.com/1'),
  ('a0000000-0000-0000-0000-000000000002', '0000000a-0000-0000-0000-000000000000',
   'QrdsA02', 'Link A2', 'https://a.example.com/2'),
  ('a0000000-0000-0000-0000-000000000003', '0000000a-0000-0000-0000-000000000000',
   'QrdsA03', 'Link A3', 'https://a.example.com/3'),
  ('b0000000-0000-0000-0000-000000000001', '0000000b-0000-0000-0000-000000000000',
   'QrdsB01', 'Link B1', 'https://b.example.com/1');

-- Diseños existentes: A2 (A) y B1 (B).
insert into public.qr_designs (link_id, org_id, fg, bg, logo_path, ecc_level) values
  ('a0000000-0000-0000-0000-000000000002', '0000000a-0000-0000-0000-000000000000',
   '#112233', '#FFFFFF', null, 'M'),
  ('b0000000-0000-0000-0000-000000000001', '0000000b-0000-0000-0000-000000000000',
   '#000000', '#FFFFFF', '0000000b-0000-0000-0000-000000000000/logo.png', 'H');

-- Objetos de storage existentes (solo metadatos) en las carpetas de A y B.
insert into storage.objects (bucket_id, name) values
  ('logos', '0000000a-0000-0000-0000-000000000000/a.png'),
  ('logos', '0000000b-0000-0000-0000-000000000000/logo.png');

create function pg_temp.login(p_uid uuid) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub', p_uid, 'role', 'authenticated')::text, true);
  execute 'set local role authenticated';
end $$;

create function pg_temp.as_anon() returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims', json_build_object('role', 'anon')::text, true);
  execute 'set local role anon';
end $$;

create function pg_temp.logout() returns void language plpgsql as $$
begin
  execute 'reset role';
  perform set_config('request.jwt.claims', '', true);
end $$;

-- -----------------------------------------------------------------------------
-- Esquema, índices y privilegios
-- -----------------------------------------------------------------------------
select has_table('public', 'qr_designs', 'existe qr_designs');
select ok((select relrowsecurity from pg_class where oid = 'public.qr_designs'::regclass),
  'RLS habilitado en qr_designs');
select col_is_pk('public', 'qr_designs', 'link_id', 'link_id es la PK');
select col_type_is('public', 'qr_designs', 'style', 'jsonb', 'style es jsonb');
select col_default_is('public', 'qr_designs', 'ecc_level', 'M', 'ecc_level default M');
select col_default_is('public', 'qr_designs', 'frame', 'none', 'frame default none');
select fk_ok('public', 'qr_designs', array['link_id', 'org_id'],
             'public', 'dynamic_links', array['id', 'org_id'],
  'FK compuesta (link_id, org_id) → dynamic_links (id, org_id)');
select is(
  (select confdeltype::text from pg_constraint where conname = 'qr_designs_link_org_fkey'),
  'c', 'la FK compuesta es on delete cascade');
select has_index('public', 'qr_designs', 'qr_designs_org_id_idx', array['org_id'], 'índice (org_id)');
select has_trigger('public', 'qr_designs', 'qr_designs_guard', 'trigger qr_designs_guard');

select ok(
  not has_table_privilege('anon', 'public.qr_designs', 'select,insert,update,delete,truncate'),
  'anon no tiene privilegios sobre qr_designs');
select ok(has_table_privilege('authenticated', 'public.qr_designs', 'select,delete'),
  'authenticated puede leer y borrar (filtrado por RLS)');
select ok(not has_table_privilege('authenticated', 'public.qr_designs', 'truncate,references,trigger'),
  'authenticated sin truncate/references/trigger');
select ok(
  not has_column_privilege('authenticated', 'public.qr_designs', 'updated_at', 'insert')
  and not has_column_privilege('authenticated', 'public.qr_designs', 'updated_at', 'update'),
  'updated_at no es escribible por authenticated');
select ok(
  has_column_privilege('authenticated', 'public.qr_designs', 'logo_path', 'insert')
  and has_column_privilege('authenticated', 'public.qr_designs', 'style', 'update'),
  'authenticated escribe las columnas de diseño');
select ok(has_table_privilege('service_role', 'public.qr_designs', 'select,insert,update,delete'),
  'service_role puede leer y escribir');

select ok(not has_function_privilege('anon', 'private.logo_path_org_id(text)', 'execute'),
  'anon no ejecuta logo_path_org_id');
select ok(not has_function_privilege('authenticated', 'private.qr_designs_guard()', 'execute'),
  'authenticated no ejecuta qr_designs_guard directamente');
select ok(
  (select p.proconfig @> array['search_path=""'] and p.provolatile = 'i'
   from pg_proc p where p.oid = 'private.logo_path_org_id(text)'::regprocedure),
  'logo_path_org_id: immutable y search_path vacío');

-- -----------------------------------------------------------------------------
-- private.logo_path_org_id
-- -----------------------------------------------------------------------------
select is(private.logo_path_org_id('0000000a-0000-0000-0000-000000000000/logo.png'),
  '0000000a-0000-0000-0000-000000000000'::uuid, 'ruta válida → org_id');
select is(private.logo_path_org_id('0000000a-0000-0000-0000-000000000000/sub/logo_1-x.webp'),
  '0000000a-0000-0000-0000-000000000000'::uuid, 'subcarpetas válidas');
select is(private.logo_path_org_id('0000000a-0000-0000-0000-000000000000/'), null,
  'sin nombre de archivo → NULL');
select is(private.logo_path_org_id('0000000a-0000-0000-0000-000000000000'), null,
  'solo la org → NULL');
select is(private.logo_path_org_id('0000000A-0000-0000-0000-000000000000/logo.png'), null,
  'uuid en mayúsculas (no canónico) → NULL');
select is(private.logo_path_org_id('0000000a-0000-0000-0000-000000000000/../b/logo.png'), null,
  'segmento .. → NULL');
select is(private.logo_path_org_id('0000000a-0000-0000-0000-000000000000/.hidden'), null,
  'segmento oculto → NULL');
select is(private.logo_path_org_id('/0000000a-0000-0000-0000-000000000000/logo.png'), null,
  'barra inicial → NULL');
select is(private.logo_path_org_id('0000000a-0000-0000-0000-000000000000//logo.png'), null,
  'segmento vacío → NULL');
select is(private.logo_path_org_id('logos/0000000a-0000-0000-0000-000000000000/logo.png'), null,
  'con el nombre del bucket delante → NULL');
select is(private.logo_path_org_id('0000000a-0000-0000-0000-000000000000/' || repeat('a', 129)), null,
  'segmento de más de 128 → NULL');
select is(private.logo_path_org_id('not-a-uuid/logo.png'), null, 'sin uuid → NULL (sin error)');
select is(private.logo_path_org_id(null), null, 'NULL → NULL');

-- -----------------------------------------------------------------------------
-- CHECKs (como postgres: las restricciones aplican a todos los roles)
-- -----------------------------------------------------------------------------
select throws_ok($$ insert into public.qr_designs (link_id, org_id, logo_path, ecc_level)
  values ('a0000000-0000-0000-0000-000000000001', '0000000a-0000-0000-0000-000000000000',
          '0000000a-0000-0000-0000-000000000000/a.png', 'M') $$,
  '23514', null, 'logo con ECC M → falla');
select throws_ok($$ insert into public.qr_designs (link_id, org_id, logo_path, ecc_level)
  values ('a0000000-0000-0000-0000-000000000001', '0000000a-0000-0000-0000-000000000000',
          '0000000a-0000-0000-0000-000000000000/a.png', 'Q') $$,
  '23514', null, 'logo con ECC Q → falla');
select throws_ok($$ update public.qr_designs set ecc_level = 'L'
  where link_id = 'b0000000-0000-0000-0000-000000000001' $$,
  '23514', null, 'bajar el ECC de un diseño con logo → falla');
select throws_ok($$ insert into public.qr_designs (link_id, org_id, logo_path, ecc_level)
  values ('a0000000-0000-0000-0000-000000000001', '0000000a-0000-0000-0000-000000000000',
          '0000000b-0000-0000-0000-000000000000/logo.png', 'H') $$,
  '23514', null, 'logo_path en la carpeta de otra org → falla');
select throws_ok($$ insert into public.qr_designs (link_id, org_id, logo_path, ecc_level)
  values ('a0000000-0000-0000-0000-000000000001', '0000000a-0000-0000-0000-000000000000',
          'logos/0000000a-0000-0000-0000-000000000000/a.png', 'H') $$,
  '23514', null, 'logo_path con formato inválido → falla');
select throws_ok($$ insert into public.qr_designs (link_id, org_id, fg)
  values ('a0000000-0000-0000-0000-000000000001', '0000000a-0000-0000-0000-000000000000', 'red') $$,
  '23514', null, 'fg no hex → falla');
select throws_ok($$ insert into public.qr_designs (link_id, org_id, fg)
  values ('a0000000-0000-0000-0000-000000000001', '0000000a-0000-0000-0000-000000000000', '#FFF') $$,
  '23514', null, 'fg hex corto → falla');
select throws_ok($$ insert into public.qr_designs (link_id, org_id, bg)
  values ('a0000000-0000-0000-0000-000000000001', '0000000a-0000-0000-0000-000000000000', '#FFFFFF00') $$,
  '23514', null, 'bg con alfa → falla');
select throws_ok($$ insert into public.qr_designs (link_id, org_id, bg)
  values ('a0000000-0000-0000-0000-000000000001', '0000000a-0000-0000-0000-000000000000', E'#FFFFFF\n') $$,
  '23514', null, 'bg con salto de línea final → falla');
select throws_ok($$ insert into public.qr_designs (link_id, org_id, frame)
  values ('a0000000-0000-0000-0000-000000000001', '0000000a-0000-0000-0000-000000000000', 'fancy') $$,
  '23514', null, 'frame fuera del catálogo → falla');
select throws_ok($$ insert into public.qr_designs (link_id, org_id, ecc_level)
  values ('a0000000-0000-0000-0000-000000000001', '0000000a-0000-0000-0000-000000000000', 'h') $$,
  '23514', null, 'ecc_level en minúscula → falla');
select throws_ok($$ insert into public.qr_designs (link_id, org_id, style)
  values ('a0000000-0000-0000-0000-000000000001', '0000000a-0000-0000-0000-000000000000', '[1,2]') $$,
  '23514', null, 'style que no es objeto → falla');
select throws_ok($$ insert into public.qr_designs (link_id, org_id, style)
  values ('a0000000-0000-0000-0000-000000000001', '0000000a-0000-0000-0000-000000000000',
          jsonb_build_object('x', repeat('a', 5000))) $$,
  '23514', null, 'style de más de 4096 bytes → falla');
select throws_ok($$ insert into public.qr_designs (link_id, org_id)
  values ('a0000000-0000-0000-0000-000000000001', '0000000b-0000-0000-0000-000000000000') $$,
  '23503', null, 'org_id distinto al del enlace → falla (FK compuesta)');
select throws_ok($$ insert into public.qr_designs (link_id, org_id)
  values ('a0000000-0000-0000-0000-000000000002', '0000000a-0000-0000-0000-000000000000') $$,
  '23505', null, 'segundo diseño para el mismo enlace → falla (PK)');
select lives_ok($$ insert into public.qr_designs (link_id, org_id, fg, bg, logo_path, frame, ecc_level, style)
  values ('a0000000-0000-0000-0000-000000000003', '0000000a-0000-0000-0000-000000000000',
          '#abcdef', '#FFFFFF', '0000000a-0000-0000-0000-000000000000/sub/a.png', 'label', 'H',
          '{"dots": "rounded"}') $$,
  'diseño completo válido (logo + ECC H) → ok');
select throws_ok($$ update public.qr_designs set org_id = '0000000b-0000-0000-0000-000000000000'
  where link_id = 'a0000000-0000-0000-0000-000000000002' $$,
  '42501', null, 'org_id es inmutable (también para postgres)');
select throws_ok($$ update public.qr_designs set link_id = 'a0000000-0000-0000-0000-000000000001'
  where link_id = 'a0000000-0000-0000-0000-000000000002' $$,
  '42501', null, 'link_id es inmutable');

-- updated_at lo fija el trigger.
update public.qr_designs set updated_at = '2000-01-01', fg = '#445566'
  where link_id = 'a0000000-0000-0000-0000-000000000002';
select ok(
  (select updated_at > '2000-01-01' from public.qr_designs
   where link_id = 'a0000000-0000-0000-0000-000000000002'),
  'updated_at se actualiza en el UPDATE (no se puede fijar)');

-- -----------------------------------------------------------------------------
-- RLS: lectura y aislamiento A/B
-- -----------------------------------------------------------------------------
select pg_temp.login('00000000-0000-0000-0000-0000000000a2');  -- viewer A
select is((select count(*)::int from public.qr_designs), 2, 'viewer A ve los 2 diseños de A');
select is((select count(*)::int from public.qr_designs where org_id = '0000000b-0000-0000-0000-000000000000'),
  0, 'viewer A no ve diseños de B');
select pg_temp.logout();

select pg_temp.login('00000000-0000-0000-0000-0000000000b1');  -- owner B
select is((select count(*)::int from public.qr_designs), 1, 'owner B solo ve su diseño');
select pg_temp.logout();

select pg_temp.login('00000000-0000-0000-0000-0000000000cc');  -- sin org
select is((select count(*)::int from public.qr_designs), 0, 'usuario sin org no ve nada');
select pg_temp.logout();

select pg_temp.login('00000000-0000-0000-0000-0000000000ff');  -- platform admin
select is((select count(*)::int from public.qr_designs), 3, 'platform admin ve todo');
select pg_temp.logout();

select pg_temp.as_anon();
select throws_ok($$ select * from public.qr_designs $$, '42501', null, 'anon no puede leer');
select pg_temp.logout();

-- -----------------------------------------------------------------------------
-- RLS: escritura por rol
-- -----------------------------------------------------------------------------
-- viewer: no crea ni actualiza.
select pg_temp.login('00000000-0000-0000-0000-0000000000a2');
select throws_ok($$ insert into public.qr_designs (link_id, org_id)
  values ('a0000000-0000-0000-0000-000000000001', '0000000a-0000-0000-0000-000000000000') $$,
  '42501', null, 'viewer no crea diseños');
update public.qr_designs set fg = '#999999' where link_id = 'a0000000-0000-0000-0000-000000000002';
select pg_temp.logout();
select is((select fg from public.qr_designs where link_id = 'a0000000-0000-0000-0000-000000000002'),
  '#445566', 'viewer no actualiza (0 filas)');

-- editor: crea, actualiza y hace upsert; no borra.
select pg_temp.login('00000000-0000-0000-0000-0000000000a3');
select lives_ok($$ insert into public.qr_designs (link_id, org_id, fg)
  values ('a0000000-0000-0000-0000-000000000001', '0000000a-0000-0000-0000-000000000000', '#010203') $$,
  'editor crea un diseño');
select throws_ok($$ insert into public.qr_designs (link_id, org_id, updated_at)
  values ('a0000000-0000-0000-0000-000000000001', '0000000a-0000-0000-0000-000000000000', now()) $$,
  '42501', null, 'editor no puede insertar updated_at (grant por columna)');
select lives_ok($$ update public.qr_designs set bg = '#F0F0F0', frame = 'rounded'
  where link_id = 'a0000000-0000-0000-0000-000000000001' $$,
  'editor actualiza un diseño');
-- Upsert como lo genera PostgREST (on_conflict=link_id, SET de todo el payload).
select lives_ok($$ insert into public.qr_designs (link_id, org_id, fg, logo_path, ecc_level)
  values ('a0000000-0000-0000-0000-000000000001', '0000000a-0000-0000-0000-000000000000',
          '#0A0B0C', '0000000a-0000-0000-0000-000000000000/a.png', 'H')
  on conflict (link_id) do update
    set link_id = excluded.link_id, org_id = excluded.org_id, fg = excluded.fg,
        logo_path = excluded.logo_path, ecc_level = excluded.ecc_level $$,
  'editor hace upsert estilo PostgREST');
select is(
  (select fg || ' ' || ecc_level || ' ' || frame from public.qr_designs
   where link_id = 'a0000000-0000-0000-0000-000000000001'),
  '#0A0B0C H rounded', 'el upsert actualiza la fila existente');
select throws_ok($$ update public.qr_designs set org_id = '0000000b-0000-0000-0000-000000000000'
  where link_id = 'a0000000-0000-0000-0000-000000000001' $$,
  '42501', null, 'editor no puede mover un diseño a otra org');
select throws_ok($$ update public.qr_designs set logo_path = '0000000b-0000-0000-0000-000000000000/logo.png'
  where link_id = 'a0000000-0000-0000-0000-000000000001' $$,
  '23514', null, 'editor no puede apuntar al logo de otra org');
select throws_ok($$ insert into public.qr_designs (link_id, org_id)
  values ('b0000000-0000-0000-0000-000000000001', '0000000b-0000-0000-0000-000000000000')
  on conflict (link_id) do update set fg = excluded.fg $$,
  '42501', null, 'editor A no hace upsert sobre un diseño de B');
update public.qr_designs set fg = '#999999' where link_id = 'b0000000-0000-0000-0000-000000000001';
delete from public.qr_designs where link_id = 'a0000000-0000-0000-0000-000000000002';
select pg_temp.logout();
select is((select fg from public.qr_designs where link_id = 'b0000000-0000-0000-0000-000000000001'),
  '#000000', 'editor A no actualiza diseños de B');
select ok(exists (select 1 from public.qr_designs where link_id = 'a0000000-0000-0000-0000-000000000002'),
  'editor no borra diseños (0 filas)');

-- owner B no toca diseños de A.
select pg_temp.login('00000000-0000-0000-0000-0000000000b1');
select throws_ok($$ insert into public.qr_designs (link_id, org_id)
  values ('a0000000-0000-0000-0000-000000000003', '0000000a-0000-0000-0000-000000000000') $$,
  '42501', null, 'owner B no crea diseños en A');
delete from public.qr_designs where org_id = '0000000a-0000-0000-0000-000000000000';
select pg_temp.logout();
select is((select count(*)::int from public.qr_designs where org_id = '0000000a-0000-0000-0000-000000000000'),
  3, 'owner B no borra diseños de A');

-- admin: borra.
select pg_temp.login('00000000-0000-0000-0000-0000000000a4');
select lives_ok($$ delete from public.qr_designs where link_id = 'a0000000-0000-0000-0000-000000000002' $$,
  'admin borra un diseño');
select pg_temp.logout();
select ok(not exists (select 1 from public.qr_designs where link_id = 'a0000000-0000-0000-0000-000000000002'),
  'el diseño quedó borrado');

-- platform admin: escribe en cualquier org.
select pg_temp.login('00000000-0000-0000-0000-0000000000ff');
select lives_ok($$ update public.qr_designs set frame = 'simple'
  where link_id = 'b0000000-0000-0000-0000-000000000001' $$,
  'platform admin actualiza en B');
select pg_temp.logout();
select is((select frame from public.qr_designs where link_id = 'b0000000-0000-0000-0000-000000000001'),
  'simple', 'el cambio del platform admin se aplicó');

-- Cascada: borrar el enlace borra su diseño.
delete from public.dynamic_links where id = 'a0000000-0000-0000-0000-000000000003';
select ok(not exists (select 1 from public.qr_designs where link_id = 'a0000000-0000-0000-0000-000000000003'),
  'borrar el enlace borra su diseño (cascade)');

-- -----------------------------------------------------------------------------
-- Storage: bucket logos
-- -----------------------------------------------------------------------------
select is((select public from storage.buckets where id = 'logos'), false, 'bucket logos es privado');
select is((select file_size_limit from storage.buckets where id = 'logos'), 1048576::bigint,
  'bucket logos: límite de 1 MiB');
select is((select allowed_mime_types from storage.buckets where id = 'logos'),
  array['image/png', 'image/jpeg', 'image/webp'], 'bucket logos: PNG/JPEG/WebP');
select ok(not exists (select 1 from storage.buckets
                      where id = 'logos' and 'image/svg+xml' = any (allowed_mime_types)),
  'SVG no está permitido');

-- Lectura.
select pg_temp.login('00000000-0000-0000-0000-0000000000a2');  -- viewer A
select is((select count(*)::int from storage.objects where bucket_id = 'logos'), 1,
  'viewer A ve solo los logos de A');
select is((select name from storage.objects where bucket_id = 'logos'),
  '0000000a-0000-0000-0000-000000000000/a.png', 'y es el logo de A');
select throws_ok($$ insert into storage.objects (bucket_id, name)
  values ('logos', '0000000a-0000-0000-0000-000000000000/viewer.png') $$,
  '42501', null, 'viewer no sube logos');
select pg_temp.logout();

select pg_temp.login('00000000-0000-0000-0000-0000000000cc');
select is((select count(*)::int from storage.objects where bucket_id = 'logos'), 0,
  'usuario sin org no ve logos');
select pg_temp.logout();

select pg_temp.as_anon();
select is((select count(*)::int from storage.objects where bucket_id = 'logos'), 0,
  'anon no ve logos');
select throws_ok($$ insert into storage.objects (bucket_id, name)
  values ('logos', '0000000a-0000-0000-0000-000000000000/anon.png') $$,
  '42501', null, 'anon no sube logos');
select pg_temp.logout();

-- Escritura del editor.
select pg_temp.login('00000000-0000-0000-0000-0000000000a3');  -- editor A
select lives_ok($$ insert into storage.objects (bucket_id, name)
  values ('logos', '0000000a-0000-0000-0000-000000000000/editor.png') $$,
  'editor A sube un logo en su carpeta');
select throws_ok($$ insert into storage.objects (bucket_id, name)
  values ('logos', '0000000b-0000-0000-0000-000000000000/evil.png') $$,
  '42501', null, 'editor A no sube en la carpeta de B');
select throws_ok($$ insert into storage.objects (bucket_id, name)
  values ('logos', 'evil.png') $$,
  '42501', null, 'editor A no sube fuera de una carpeta de org');
select throws_ok($$ insert into storage.objects (bucket_id, name)
  values ('logos', '0000000a-0000-0000-0000-000000000000/../0000000b-0000-0000-0000-000000000000/x.png') $$,
  '42501', null, 'editor A no sube con .. en la ruta');
select throws_ok($$ insert into storage.objects (bucket_id, name)
  values ('other', '0000000a-0000-0000-0000-000000000000/x.png') $$,
  '42501', null, 'las políticas de logos no abren otros buckets');
select lives_ok($$ update storage.objects set metadata = '{"v": 2}'
  where bucket_id = 'logos' and name = '0000000a-0000-0000-0000-000000000000/editor.png' $$,
  'editor A reemplaza (update) su logo');
select throws_ok($$ update storage.objects set name = '0000000b-0000-0000-0000-000000000000/moved.png'
  where bucket_id = 'logos' and name = '0000000a-0000-0000-0000-000000000000/editor.png' $$,
  '42501', null, 'editor A no mueve un logo a la carpeta de B');
update storage.objects set metadata = '{"pwned": true}'
  where bucket_id = 'logos' and name = '0000000b-0000-0000-0000-000000000000/logo.png';
set local storage.allow_delete_query = 'true';
delete from storage.objects
  where bucket_id = 'logos' and name = '0000000b-0000-0000-0000-000000000000/logo.png';
select lives_ok($$ delete from storage.objects
  where bucket_id = 'logos' and name = '0000000a-0000-0000-0000-000000000000/editor.png' $$,
  'editor A borra su logo');
reset storage.allow_delete_query;
select pg_temp.logout();
select ok(
  (select metadata is null from storage.objects
   where bucket_id = 'logos' and name = '0000000b-0000-0000-0000-000000000000/logo.png'),
  'editor A no modifica ni borra el logo de B');
select ok(not exists (select 1 from storage.objects
   where bucket_id = 'logos' and name = '0000000a-0000-0000-0000-000000000000/editor.png'),
  'el logo del editor quedó borrado');

-- owner B escribe en su carpeta; platform admin en cualquiera con ruta válida.
select pg_temp.login('00000000-0000-0000-0000-0000000000b1');
select lives_ok($$ insert into storage.objects (bucket_id, name)
  values ('logos', '0000000b-0000-0000-0000-000000000000/b2.png') $$,
  'owner B sube en su carpeta');
select throws_ok($$ insert into storage.objects (bucket_id, name)
  values ('logos', '0000000a-0000-0000-0000-000000000000/fromb.png') $$,
  '42501', null, 'owner B no sube en la carpeta de A');
select pg_temp.logout();

select pg_temp.login('00000000-0000-0000-0000-0000000000ff');
select lives_ok($$ insert into storage.objects (bucket_id, name)
  values ('logos', '0000000a-0000-0000-0000-000000000000/pa.png') $$,
  'platform admin sube en cualquier org');
select throws_ok($$ insert into storage.objects (bucket_id, name)
  values ('logos', 'sin-org.png') $$,
  '42501', null, 'platform admin tampoco sube fuera de una carpeta de org');
select pg_temp.logout();

select * from finish();
rollback;
