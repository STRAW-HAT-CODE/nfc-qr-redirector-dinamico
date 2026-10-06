-- DQR-T013 · Tests de tenancy y RLS (pgTAP). Ejecutar: supabase test db
-- Todo corre dentro de BEGIN … ROLLBACK: no deja datos.
begin;

create extension if not exists pgtap with schema extensions;

select plan(66);

-- -----------------------------------------------------------------------------
-- Fixtures (como postgres)
-- -----------------------------------------------------------------------------
-- a1 owner A · a2 viewer A · a3 admin A · e1 editor A · b1 owner B · pa platform admin · x sin org
insert into auth.users (id, email, aud, role) values
  ('00000000-0000-0000-0000-0000000000a1', 'a1@test.local', 'authenticated', 'authenticated'),
  ('00000000-0000-0000-0000-0000000000a2', 'a2@test.local', 'authenticated', 'authenticated'),
  ('00000000-0000-0000-0000-0000000000a3', 'a3@test.local', 'authenticated', 'authenticated'),
  ('00000000-0000-0000-0000-0000000000e1', 'e1@test.local', 'authenticated', 'authenticated'),
  ('00000000-0000-0000-0000-0000000000b1', 'b1@test.local', 'authenticated', 'authenticated'),
  ('00000000-0000-0000-0000-0000000000ff', 'pa@test.local', 'authenticated', 'authenticated'),
  ('00000000-0000-0000-0000-0000000000cc', 'x@test.local',  'authenticated', 'authenticated');

insert into public.platform_admins (user_id) values ('00000000-0000-0000-0000-0000000000ff');

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
-- Esquema
-- -----------------------------------------------------------------------------
select has_table('public', 'organizations', 'existe organizations');
select has_table('public', 'memberships', 'existe memberships');
select has_table('public', 'platform_admins', 'existe platform_admins');

select ok(
  (select bool_and(c.relrowsecurity) from pg_class c
   where c.oid in ('public.organizations'::regclass, 'public.memberships'::regclass,
                   'public.platform_admins'::regclass)),
  'RLS habilitado en las 3 tablas');

select is(
  (select count(*)::int from pg_policies where schemaname = 'public' and tablename = 'platform_admins'),
  0, 'platform_admins no tiene políticas (solo service role)');

select has_index('public', 'memberships', 'memberships_user_id_idx', 'índice en memberships.user_id');

select ok(
  (select bool_and(p.prosecdef and p.provolatile = 's' and p.proconfig @> array['search_path=""'])
   from pg_proc p join pg_namespace n on n.oid = p.pronamespace
   where n.nspname = 'private' and p.proname in ('is_org_member', 'has_org_role', 'is_platform_admin')),
  'helpers: SECURITY DEFINER, STABLE y search_path vacío');

select ok(
  not has_function_privilege('anon', 'private.is_org_member(uuid)', 'execute')
  and not has_function_privilege('anon', 'private.has_org_role(uuid, public.org_role)', 'execute')
  and not has_function_privilege('anon', 'private.is_platform_admin()', 'execute')
  and not has_function_privilege('anon', 'public.create_organization(text, text)', 'execute'),
  'anon no puede ejecutar helpers ni create_organization');

select ok(
  has_function_privilege('authenticated', 'private.is_org_member(uuid)', 'execute')
  and has_function_privilege('authenticated', 'private.has_org_role(uuid, public.org_role)', 'execute')
  and has_function_privilege('authenticated', 'private.is_platform_admin()', 'execute')
  and has_function_privilege('authenticated', 'public.create_organization(text, text)', 'execute'),
  'authenticated puede ejecutar helpers y create_organization');

select ok('viewer'::public.org_role < 'editor' and 'editor'::public.org_role < 'admin'
          and 'admin'::public.org_role < 'owner', 'jerarquía viewer<editor<admin<owner');

-- -----------------------------------------------------------------------------
-- create_organization: creador = owner
-- -----------------------------------------------------------------------------
select pg_temp.login(null);
select throws_ok($$ select public.create_organization('Sin usuario', 'sin-usuario') $$,
  '42501', null, 'create_organization exige usuario autenticado');
select pg_temp.logout();

select pg_temp.login('00000000-0000-0000-0000-0000000000a1');
select lives_ok($$ select public.create_organization('Org A', 'org-a') $$, 'a1 crea Org A');
select throws_ok($$ insert into public.organizations (name, slug) values ('Directa', 'directa') $$,
  '42501', null, 'INSERT directo en organizations está prohibido');
select throws_ok($$ select public.create_organization('Org A bis', 'org-a') $$,
  '23505', null, 'slug de organización único');
select throws_ok($$ select public.create_organization('Mal slug', 'Mal Slug!') $$,
  '23514', null, 'slug con formato inválido');
select pg_temp.logout();

select pg_temp.login('00000000-0000-0000-0000-0000000000b1');
select lives_ok($$ select public.create_organization('Org B', 'org-b') $$, 'b1 crea Org B');
select pg_temp.logout();

select set_config('test.org_a', (select id::text from public.organizations where slug = 'org-a'), true);
select set_config('test.org_b', (select id::text from public.organizations where slug = 'org-b'), true);

select is(
  (select role from public.memberships
   where org_id = current_setting('test.org_a')::uuid
     and user_id = '00000000-0000-0000-0000-0000000000a1'),
  'owner'::public.org_role, 'el creador de Org A es owner');
select is(
  (select count(*)::int from public.memberships where org_id = current_setting('test.org_a')::uuid),
  1, 'Org A nace con una sola membresía');

-- -----------------------------------------------------------------------------
-- Gestión de miembros por rol
-- -----------------------------------------------------------------------------
select pg_temp.login('00000000-0000-0000-0000-0000000000a1');
select lives_ok($$ insert into public.memberships (org_id, user_id, role)
  values (current_setting('test.org_a')::uuid, '00000000-0000-0000-0000-0000000000a3', 'admin') $$,
  'owner añade un admin');
select lives_ok($$ insert into public.memberships (org_id, user_id, role)
  values (current_setting('test.org_a')::uuid, '00000000-0000-0000-0000-0000000000e1', 'editor') $$,
  'owner añade un editor');
select throws_ok($$ update public.organizations set created_at = '1999-01-01'
  where id = current_setting('test.org_a')::uuid $$,
  '42501', null, 'created_at de organizations es inmutable');
select throws_ok($$ update public.organizations set slug = 'org-a-nuevo'
  where id = current_setting('test.org_a')::uuid $$,
  '42501', null, 'owner no puede cambiar el slug de la org');
select throws_ok($$ insert into public.memberships (org_id, user_id, role, created_at)
  values (current_setting('test.org_a')::uuid, '00000000-0000-0000-0000-0000000000cc', 'viewer', '1999-01-01') $$,
  '42501', null, 'created_at de memberships no se puede fijar al insertar');
select pg_temp.logout();

select pg_temp.login('00000000-0000-0000-0000-0000000000a3');
select lives_ok($$ insert into public.memberships (org_id, user_id, role)
  values (current_setting('test.org_a')::uuid, '00000000-0000-0000-0000-0000000000a2', 'viewer') $$,
  'admin añade un viewer');
select throws_ok($$ insert into public.memberships (org_id, user_id, role)
  values (current_setting('test.org_a')::uuid, '00000000-0000-0000-0000-0000000000cc', 'owner') $$,
  '42501', null, 'admin no puede crear owners');
select is((select count(*)::int from public.memberships), 4, 'admin ve todas las membresías de su org');
select throws_ok($$ update public.memberships set role = 'owner'
  where user_id = '00000000-0000-0000-0000-0000000000a2' $$,
  '42501', null, 'admin no puede promover a owner');
delete from public.memberships where user_id = '00000000-0000-0000-0000-0000000000a1';
update public.memberships set role = 'viewer' where user_id = '00000000-0000-0000-0000-0000000000a1';
update public.organizations set name = 'Org A renombrada' where id = current_setting('test.org_a')::uuid;
select throws_ok($$ update public.organizations set plan = 'pro' where id = current_setting('test.org_a')::uuid $$,
  '42501', null, 'admin no puede cambiar el plan');
select throws_ok($$ update public.organizations set status = 'suspended' where id = current_setting('test.org_a')::uuid $$,
  '42501', null, 'admin no puede suspender la org');
delete from public.organizations where id = current_setting('test.org_a')::uuid;
select pg_temp.logout();

select is(
  (select role from public.memberships where user_id = '00000000-0000-0000-0000-0000000000a1'),
  'owner'::public.org_role, 'admin no puede quitar ni degradar a un owner');
select is((select name from public.organizations where id = current_setting('test.org_a')::uuid),
  'Org A renombrada', 'admin puede renombrar su org');
select ok(exists (select 1 from public.organizations where id = current_setting('test.org_a')::uuid),
  'admin no puede borrar la org');

select pg_temp.login('00000000-0000-0000-0000-0000000000a2');
select is((select count(*)::int from public.memberships), 1, 'viewer solo ve su propia membresía');
select is((select count(*)::int from public.organizations), 1, 'viewer ve su org');
select throws_ok($$ insert into public.memberships (org_id, user_id, role)
  values (current_setting('test.org_a')::uuid, '00000000-0000-0000-0000-0000000000cc', 'viewer') $$,
  '42501', null, 'viewer no puede añadir miembros');
update public.memberships set role = 'admin' where user_id = '00000000-0000-0000-0000-0000000000a2';
update public.organizations set name = 'hack' where id = current_setting('test.org_a')::uuid;
select throws_ok($$ update public.memberships set user_id = '00000000-0000-0000-0000-0000000000cc'
  where user_id = '00000000-0000-0000-0000-0000000000a2' $$,
  '42501', null, 'user_id de una membresía no es editable');
select pg_temp.logout();

select is((select role from public.memberships where user_id = '00000000-0000-0000-0000-0000000000a2'),
  'viewer'::public.org_role, 'viewer no puede autopromoverse');
select is((select name from public.organizations where id = current_setting('test.org_a')::uuid),
  'Org A renombrada', 'viewer no puede editar la org');

select pg_temp.login('00000000-0000-0000-0000-0000000000e1');
select throws_ok($$ insert into public.memberships (org_id, user_id, role)
  values (current_setting('test.org_a')::uuid, '00000000-0000-0000-0000-0000000000cc', 'viewer') $$,
  '42501', null, 'editor no puede añadir miembros');
update public.organizations set name = 'editor-hack' where id = current_setting('test.org_a')::uuid;
select pg_temp.logout();
select isnt((select name from public.organizations where id = current_setting('test.org_a')::uuid),
  'editor-hack', 'editor no puede editar la org');

-- -----------------------------------------------------------------------------
-- Aislamiento org A / org B
-- -----------------------------------------------------------------------------
select pg_temp.login('00000000-0000-0000-0000-0000000000a1');
select is((select count(*)::int from public.organizations), 1, 'a1 solo ve Org A');
select is((select count(*)::int from public.memberships where org_id = current_setting('test.org_b')::uuid),
  0, 'a1 no ve membresías de Org B');
select ok(not private.is_org_member(current_setting('test.org_b')::uuid), 'is_org_member(B) = false para a1');
select ok(private.has_org_role(current_setting('test.org_a')::uuid, 'owner'), 'has_org_role(A, owner) para a1');
select throws_ok($$ insert into public.memberships (org_id, user_id, role)
  values (current_setting('test.org_b')::uuid, '00000000-0000-0000-0000-0000000000a1', 'owner') $$,
  '42501', null, 'a1 no puede unirse a Org B');
update public.organizations set name = 'pwned' where id = current_setting('test.org_b')::uuid;
update public.memberships set role = 'viewer' where org_id = current_setting('test.org_b')::uuid;
delete from public.memberships where org_id = current_setting('test.org_b')::uuid;
delete from public.organizations where id = current_setting('test.org_b')::uuid;
select throws_ok($$ select * from public.platform_admins $$, '42501', null,
  'authenticated no puede leer platform_admins');
select pg_temp.logout();

select is((select name from public.organizations where id = current_setting('test.org_b')::uuid),
  'Org B', 'Org B intacta tras intentos de a1 (update/delete)');
select is((select role from public.memberships
           where org_id = current_setting('test.org_b')::uuid
             and user_id = '00000000-0000-0000-0000-0000000000b1'),
  'owner'::public.org_role, 'membresía owner de Org B intacta');

select pg_temp.login('00000000-0000-0000-0000-0000000000cc');
select is((select count(*)::int from public.organizations), 0, 'usuario sin org no ve organizaciones');
select throws_ok($$ insert into public.memberships (org_id, user_id, role)
  values (current_setting('test.org_a')::uuid, '00000000-0000-0000-0000-0000000000cc', 'viewer') $$,
  '42501', null, 'usuario ajeno no puede unirse a Org A como viewer');
select throws_ok($$ insert into public.platform_admins (user_id)
  values ('00000000-0000-0000-0000-0000000000cc') $$,
  '42501', null, 'authenticated no puede auto-insertarse en platform_admins');
select throws_ok($$ delete from public.platform_admins $$,
  '42501', null, 'authenticated no puede borrar platform_admins');
select pg_temp.logout();

-- anon
set local role anon;
select throws_ok($$ select * from public.organizations $$, '42501', null, 'anon no lee organizations');
select throws_ok($$ select * from public.memberships $$, '42501', null, 'anon no lee memberships');
select throws_ok($$ select public.create_organization('x', 'anon-org') $$, '42501', null, 'anon no llama a create_organization');
reset role;

-- Platform admin
select pg_temp.login('00000000-0000-0000-0000-0000000000ff');
select is((select count(*)::int from public.organizations), 2, 'platform admin ve todas las orgs');
select lives_ok($$ update public.organizations set plan = 'pro', status = 'suspended'
  where id = current_setting('test.org_b')::uuid $$, 'platform admin cambia plan/status');
select lives_ok($$ update public.organizations set slug = 'org-b-nuevo'
  where id = current_setting('test.org_b')::uuid $$, 'platform admin cambia el slug');
select pg_temp.logout();
select is((select plan from public.organizations where id = current_setting('test.org_b')::uuid),
  'pro', 'plan de Org B actualizado por platform admin');

-- -----------------------------------------------------------------------------
-- Último owner
-- -----------------------------------------------------------------------------
select pg_temp.login('00000000-0000-0000-0000-0000000000a1');
select throws_ok($$ update public.memberships set role = 'admin'
  where org_id = current_setting('test.org_a')::uuid and user_id = '00000000-0000-0000-0000-0000000000a1' $$,
  'P0001', null, 'no se puede degradar al último owner');
select throws_ok($$ delete from public.memberships
  where org_id = current_setting('test.org_a')::uuid and user_id = '00000000-0000-0000-0000-0000000000a1' $$,
  'P0001', null, 'no se puede quitar al último owner');
select lives_ok($$ update public.memberships set role = 'owner'
  where org_id = current_setting('test.org_a')::uuid and user_id = '00000000-0000-0000-0000-0000000000a3' $$,
  'owner promueve a otro owner');
select lives_ok($$ update public.memberships set role = 'admin'
  where org_id = current_setting('test.org_a')::uuid and user_id = '00000000-0000-0000-0000-0000000000a1' $$,
  'con otro owner, el owner puede degradarse');
select pg_temp.logout();

-- La regla aplica también a service role / postgres.
select throws_ok($$ delete from public.memberships
  where org_id = current_setting('test.org_b')::uuid and user_id = '00000000-0000-0000-0000-0000000000b1' $$,
  'P0001', null, 'el último owner tampoco se quita con privilegios de servicio');

-- Borrar la org (owner) sí elimina sus membresías en cascada.
select pg_temp.login('00000000-0000-0000-0000-0000000000b1');
delete from public.organizations where id = current_setting('test.org_b')::uuid;
select pg_temp.logout();
select ok(not exists (select 1 from public.organizations where id = current_setting('test.org_b')::uuid),
  'owner puede borrar su org');
select is((select count(*)::int from public.memberships where org_id = current_setting('test.org_b')::uuid),
  0, 'membresías de la org borrada eliminadas en cascada');

select * from finish();
rollback;
