-- DQR-T053 · Tests de planes y límites (pgTAP).
-- Ejecutar: supabase test db. Todo corre dentro de BEGIN … ROLLBACK salvo la
-- prueba de carrera, que necesita dos sesiones reales (dblink) y por eso
-- confirma datos propios (org 'race-t053') y los borra al terminar (también
-- al empezar, por si una ejecución anterior se interrumpió).
begin;

create extension if not exists pgtap with schema extensions;
create extension if not exists dblink with schema extensions;

select plan(85);

-- -----------------------------------------------------------------------------
-- Fixtures (como postgres: exento de límites)
-- -----------------------------------------------------------------------------
-- Org A (free): o1 owner · ad admin · ed editor · vw viewer (4 miembros: ya por
--   encima del máximo free de 3 → se conservan, solo se bloquean altas).
-- Org B (free): ob owner. pa platform admin. u5 sin org. m1..m3 candidatos.
insert into auth.users (id, email, aud, role) values
  ('00000000-0000-0000-0000-0000000000a1', 'o1@test.local', 'authenticated', 'authenticated'),
  ('00000000-0000-0000-0000-0000000000ad', 'ad@test.local', 'authenticated', 'authenticated'),
  ('00000000-0000-0000-0000-0000000000ed', 'ed@test.local', 'authenticated', 'authenticated'),
  ('00000000-0000-0000-0000-0000000000a2', 'vw@test.local', 'authenticated', 'authenticated'),
  ('00000000-0000-0000-0000-0000000000b1', 'ob@test.local', 'authenticated', 'authenticated'),
  ('00000000-0000-0000-0000-0000000000ff', 'pa@test.local', 'authenticated', 'authenticated'),
  ('00000000-0000-0000-0000-0000000000c5', 'u5@test.local', 'authenticated', 'authenticated'),
  ('00000000-0000-0000-0000-0000000000d1', 'm1@test.local', 'authenticated', 'authenticated'),
  ('00000000-0000-0000-0000-0000000000d2', 'm2@test.local', 'authenticated', 'authenticated'),
  ('00000000-0000-0000-0000-0000000000d3', 'm3@test.local', 'authenticated', 'authenticated');

insert into public.platform_admins (user_id) values ('00000000-0000-0000-0000-0000000000ff');

insert into public.organizations (id, name, slug) values
  ('0000000a-0000-0000-0000-000000000000', 'Org A', 'org-a'),
  ('0000000b-0000-0000-0000-000000000000', 'Org B', 'org-b');

insert into public.memberships (org_id, user_id, role) values
  ('0000000a-0000-0000-0000-000000000000', '00000000-0000-0000-0000-0000000000a1', 'owner'),
  ('0000000a-0000-0000-0000-000000000000', '00000000-0000-0000-0000-0000000000ad', 'admin'),
  ('0000000a-0000-0000-0000-000000000000', '00000000-0000-0000-0000-0000000000ed', 'editor'),
  ('0000000a-0000-0000-0000-000000000000', '00000000-0000-0000-0000-0000000000a2', 'viewer'),
  ('0000000b-0000-0000-0000-000000000000', '00000000-0000-0000-0000-0000000000b1', 'owner');

-- 9 enlaces en A (máximo free: 10). Ids a1000000-…-00000000000N.
insert into public.dynamic_links (id, org_id, name, destination_url)
select ('a1000000-0000-0000-0000-' || lpad(i::text, 12, '0'))::uuid,
       '0000000a-0000-0000-0000-000000000000', 'L' || i, 'https://a.example.com/' || i
from generate_series(1, 9) i;

-- 10 etiquetas NFC en A (máximo free: 10).
insert into public.nfc_tags (link_id, org_id, label)
select 'a1000000-0000-0000-0000-000000000001', '0000000a-0000-0000-0000-000000000000', 'T' || i
from generate_series(1, 10) i;

-- 5 diseños con logo en A, enlaces 1..5 (máximo free: 5).
insert into public.qr_designs (link_id, org_id, logo_path, ecc_level)
select ('a1000000-0000-0000-0000-' || lpad(i::text, 12, '0'))::uuid,
       '0000000a-0000-0000-0000-000000000000',
       '0000000a-0000-0000-0000-000000000000/logo' || i || '.png', 'H'
from generate_series(1, 5) i;

create function pg_temp.login(p_uid uuid) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims',
    json_build_object('sub', p_uid, 'role', 'authenticated')::text, true);
  execute 'set local role authenticated';
end $$;

create function pg_temp.as_role(p_role text) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims', json_build_object('role', p_role)::text, true);
  execute format('set local role %I', p_role);
end $$;

create function pg_temp.logout() returns void language plpgsql as $$
begin
  execute 'reset role';
  perform set_config('request.jwt.claims', '', true);
end $$;

-- Ejecuta p_sql y devuelve 'ok' o 'SQLSTATE|hint' (el hint es lo que usa la API).
create function pg_temp.err(p_sql text) returns text language plpgsql as $$
declare v_hint text;
begin
  execute p_sql;
  return 'ok';
exception when others then
  get stacked diagnostics v_hint = pg_exception_hint;
  return sqlstate || '|' || coalesce(v_hint, '');
end $$;

-- SQL de alta reutilizable.
create function pg_temp.new_link_sql(p_org uuid default '0000000a-0000-0000-0000-000000000000')
returns text language sql as $$
  select format(
    'insert into public.dynamic_links (org_id, name, destination_url) values (%L, %L, %L)',
    p_org, 'nuevo', 'https://a.example.com/nuevo');
$$;

create function pg_temp.new_tag_sql() returns text language sql as $$
  select $q$insert into public.nfc_tags (link_id, org_id, label)
            values ('a1000000-0000-0000-0000-000000000001',
                    '0000000a-0000-0000-0000-000000000000', 'nueva')$q$;
$$;

create function pg_temp.new_member_sql(p_uid uuid, p_role text default 'viewer')
returns text language sql as $$
  select format(
    'insert into public.memberships (org_id, user_id, role) values (%L, %L, %L)',
    '0000000a-0000-0000-0000-000000000000', p_uid, p_role);
$$;

create function pg_temp.set_limits(p_org uuid, p_limits jsonb) returns void
language sql as $$
  update public.organizations set limits = p_limits where id = p_org;
$$;

-- -----------------------------------------------------------------------------
-- Estructura y catálogo
-- -----------------------------------------------------------------------------
select has_table('public', 'plans', 'existe public.plans');
select ok((select relrowsecurity from pg_class where oid = 'public.plans'::regclass),
  'RLS activo en plans');
select results_eq(
  $$ select code from public.plans order by code $$,
  $$ values ('business'), ('free'), ('pro') $$,
  'seed: free, pro y business');
select is(
  (select limits from public.plans where code = 'free'),
  '{"max_links": 10, "max_members": 3, "max_nfc_tags": 10, "max_logos": 5, "scans_retention_days": 30}'::jsonb,
  'límites del plan free');
select ok(
  (select bool_and((p.limits ->> 'max_links')::int <= (q.limits ->> 'max_links')::int)
   from public.plans p join public.plans q
     on (p.code, q.code) in (('free', 'pro'), ('pro', 'business'))),
  'los planes crecen: free ≤ pro ≤ business');
select fk_ok('public', 'organizations', 'plan', 'public', 'plans', 'code',
  'organizations.plan → plans.code');
select is((select plan from public.organizations where slug = 'org-a'), 'free',
  'una org nueva es free por defecto');
select has_trigger('public', 'dynamic_links', 'dynamic_links_plan_limit', 'trigger de límite en dynamic_links');
select has_trigger('public', 'memberships', 'memberships_plan_limit', 'trigger de límite en memberships');
select has_trigger('public', 'nfc_tags', 'nfc_tags_plan_limit', 'trigger de límite en nfc_tags');
select has_trigger('public', 'qr_designs', 'qr_designs_plan_limit', 'trigger de límite en qr_designs');
select ok(
  not has_function_privilege('anon', 'private.enforce_plan_limit(uuid, text, uuid)', 'execute')
  and not has_function_privilege('anon', 'private.org_limit(uuid, text)', 'execute')
  and not has_function_privilege('authenticated', 'private.plan_limit_guard()', 'execute'),
  'anon no ejecuta helpers de límites; authenticated no ejecuta el trigger');

-- -----------------------------------------------------------------------------
-- Lectura y escritura de plans
-- -----------------------------------------------------------------------------
select pg_temp.login('00000000-0000-0000-0000-0000000000a2');
select is((select count(*)::int from public.plans), 3, 'authenticated (viewer) lee los 3 planes');
select pg_temp.logout();
select pg_temp.login('00000000-0000-0000-0000-0000000000c5');
select is((select count(*)::int from public.plans), 3, 'un usuario sin org también lee los planes');
select throws_ok($$ insert into public.plans (code, name, limits) values ('x', 'X', '{}') $$,
  '42501', null, 'authenticated no crea planes');
select throws_ok($$ update public.plans set name = 'Gratis' where code = 'free' $$,
  '42501', null, 'authenticated no edita planes');
select throws_ok($$ delete from public.plans where code = 'pro' $$,
  '42501', null, 'authenticated no borra planes');
select pg_temp.logout();

select pg_temp.login('00000000-0000-0000-0000-0000000000ff');
select throws_ok($$ update public.plans set name = 'Gratis' where code = 'free' $$,
  '42501', null, 'platform admin tampoco edita planes con su JWT (solo service_role)');
select pg_temp.logout();

select pg_temp.as_role('anon');
select throws_ok($$ select * from public.plans $$, '42501', null, 'anon no lee planes');
select pg_temp.logout();

select pg_temp.as_role('service_role');
select lives_ok($$ update public.plans set name = 'Free' where code = 'free' $$,
  'service_role edita planes');
select throws_ok(
  $$ update public.plans set limits = limits - 'max_logos' where code = 'free' $$,
  '23514', null, 'plans.limits exige todas las claves');
select throws_ok(
  $$ update public.plans set limits = limits || '{"max_links": -1}' where code = 'free' $$,
  '23514', null, 'plans.limits rechaza negativos');
select throws_ok(
  $$ update public.plans set limits = limits || '{"max_links": "10"}' where code = 'free' $$,
  '23514', null, 'plans.limits rechaza strings');
select throws_ok(
  $$ update public.plans set limits = limits || '{"max_foo": 1}' where code = 'free' $$,
  '23514', null, 'plans.limits rechaza claves desconocidas');
select throws_ok($$ delete from public.plans where code = 'free' $$,
  '23503', null, 'no se borra un plan en uso');
select throws_ok(
  $$ update public.organizations set plan = 'gold' where slug = 'org-b' $$,
  '23503', null, 'organizations.plan debe existir en plans');
select throws_ok(
  $$ update public.organizations set limits = '{"max_links": 1.5}' where slug = 'org-b' $$,
  '23514', null, 'organizations.limits con formato inválido');
select lives_ok(
  $$ update public.organizations set limits = '{"max_links": null}' where slug = 'org-b' $$,
  'organizations.limits admite override parcial con null (ilimitado)');
select lives_ok(
  $$ update public.organizations set limits = '{}', plan = 'free' where slug = 'org-b' $$,
  'service_role cambia plan y limits');
select pg_temp.logout();

-- -----------------------------------------------------------------------------
-- Solo platform admin / service_role cambian plan y limits (organizations_guard)
-- -----------------------------------------------------------------------------
select pg_temp.login('00000000-0000-0000-0000-0000000000a1');
select throws_ok($$ update public.organizations set plan = 'business' where slug = 'org-a' $$,
  '42501', null, 'owner no cambia el plan');
select throws_ok($$ update public.organizations set limits = '{"max_links": 1000}' where slug = 'org-a' $$,
  '42501', null, 'owner no cambia limits');
select pg_temp.logout();

select pg_temp.login('00000000-0000-0000-0000-0000000000ad');
select throws_ok($$ update public.organizations set plan = 'pro' where slug = 'org-a' $$,
  '42501', null, 'admin de org no cambia el plan');
select pg_temp.logout();

select pg_temp.login('00000000-0000-0000-0000-0000000000ff');
select lives_ok($$ update public.organizations set plan = 'pro' where slug = 'org-b' $$,
  'platform admin cambia el plan');
select lives_ok($$ update public.organizations set plan = 'free' where slug = 'org-b' $$,
  'platform admin vuelve a free');
select pg_temp.logout();

-- -----------------------------------------------------------------------------
-- Límite efectivo
-- -----------------------------------------------------------------------------
select is(private.org_limit('0000000a-0000-0000-0000-000000000000', 'max_links'), 10::bigint,
  'sin override: límite del plan');
select pg_temp.set_limits('0000000b-0000-0000-0000-000000000000', '{"max_links": 2}');
select is(private.org_limit('0000000b-0000-0000-0000-000000000000', 'max_links'), 2::bigint,
  'override por org sobre el plan');
select is(private.org_limit('0000000b-0000-0000-0000-000000000000', 'max_members'), 3::bigint,
  'claves sin override heredan del plan');
select pg_temp.set_limits('0000000b-0000-0000-0000-000000000000', '{"max_links": null}');
select is(private.org_limit('0000000b-0000-0000-0000-000000000000', 'max_links'), null::bigint,
  'override null = ilimitado');
select pg_temp.set_limits('0000000b-0000-0000-0000-000000000000', '{}');

-- -----------------------------------------------------------------------------
-- Enlaces (free: 10; hay 9)
-- -----------------------------------------------------------------------------
select pg_temp.login('00000000-0000-0000-0000-0000000000ed');
select is(pg_temp.err(pg_temp.new_link_sql()), 'ok', 'editor crea el enlace 10/10');
select is(pg_temp.err(pg_temp.new_link_sql()), 'P0001|plan_limit_reached',
  'enlace 11 → P0001 plan_limit_reached');
select throws_ok(pg_temp.new_link_sql(), 'P0001',
  'Has alcanzado el límite de tu plan: máximo 10 enlaces',
  'mensaje claro con recurso y límite');
select pg_temp.logout();

select pg_temp.login('00000000-0000-0000-0000-0000000000a2');
select is(pg_temp.err(pg_temp.new_link_sql()), '42501|',
  'viewer sigue recibiendo 42501 (RLS), no el error de plan');
select pg_temp.logout();

select pg_temp.login('00000000-0000-0000-0000-0000000000b1');
select is(pg_temp.err(pg_temp.new_link_sql()), '42501|',
  'un no miembro recibe 42501: no se revela el uso de otra org');
select pg_temp.logout();

select pg_temp.login('00000000-0000-0000-0000-0000000000ff');
select is(pg_temp.err(pg_temp.new_link_sql()), 'ok', 'platform admin exento (enlace 11)');
select pg_temp.logout();

select pg_temp.as_role('service_role');
select is(pg_temp.err(pg_temp.new_link_sql()), 'ok', 'service_role exento (enlace 12)');
select pg_temp.logout();

-- Override por org.
select pg_temp.login('00000000-0000-0000-0000-0000000000ff');
select lives_ok($$ update public.organizations set limits = '{"max_links": 13}' where slug = 'org-a' $$,
  'platform admin fija override max_links = 13');
select pg_temp.logout();

select pg_temp.login('00000000-0000-0000-0000-0000000000ed');
select is(pg_temp.err(pg_temp.new_link_sql()), 'ok', 'con override: enlace 13/13');
select throws_ok(pg_temp.new_link_sql(), 'P0001',
  'Has alcanzado el límite de tu plan: máximo 13 enlaces', 'con override: enlace 14 rechazado');
select pg_temp.logout();

-- Borrar libera hueco.
select pg_temp.login('00000000-0000-0000-0000-0000000000ad');
select lives_ok($$ delete from public.dynamic_links where id = 'a1000000-0000-0000-0000-000000000009' $$,
  'admin borra un enlace');
select pg_temp.logout();
select pg_temp.login('00000000-0000-0000-0000-0000000000ed');
select is(pg_temp.err(pg_temp.new_link_sql()), 'ok', 'tras borrar, cabe otro enlace');
select pg_temp.logout();

select pg_temp.set_limits('0000000a-0000-0000-0000-000000000000', '{"max_links": null}');
select pg_temp.login('00000000-0000-0000-0000-0000000000ed');
select is(pg_temp.err(pg_temp.new_link_sql()), 'ok', 'override null: sin límite de enlaces');
select pg_temp.logout();

-- Org B (free, 0 enlaces): el límite es por org.
select pg_temp.login('00000000-0000-0000-0000-0000000000b1');
select is(pg_temp.err(pg_temp.new_link_sql('0000000b-0000-0000-0000-000000000000')), 'ok',
  'el uso de A no afecta a B');
select pg_temp.logout();

-- -----------------------------------------------------------------------------
-- Miembros (free: 3; A ya tiene 4)
-- -----------------------------------------------------------------------------
select pg_temp.login('00000000-0000-0000-0000-0000000000ad');
select is(pg_temp.err(pg_temp.new_member_sql('00000000-0000-0000-0000-0000000000d1')),
  'P0001|plan_limit_reached', 'admin no añade un 5º miembro (máx. 3)');
select throws_ok(pg_temp.new_member_sql('00000000-0000-0000-0000-0000000000d1'), 'P0001',
  'Has alcanzado el límite de tu plan: máximo 3 miembros', 'mensaje de miembros');
select pg_temp.logout();

select pg_temp.login('00000000-0000-0000-0000-0000000000ed');
select is(pg_temp.err(pg_temp.new_member_sql('00000000-0000-0000-0000-0000000000d1')), '42501|',
  'editor recibe 42501 (RLS), no el error de plan');
select pg_temp.logout();

select is((select count(*)::int from public.memberships
           where org_id = '0000000a-0000-0000-0000-000000000000'), 4,
  'las membresías existentes por encima del límite se conservan');

select pg_temp.login('00000000-0000-0000-0000-0000000000ff');
select is(pg_temp.err(pg_temp.new_member_sql('00000000-0000-0000-0000-0000000000d1')), 'ok',
  'platform admin exento (5º miembro)');
select lives_ok($$ update public.organizations set limits = '{"max_members": 6}' where slug = 'org-a' $$,
  'platform admin fija override max_members = 6');
select pg_temp.logout();

select pg_temp.login('00000000-0000-0000-0000-0000000000ad');
select is(pg_temp.err(pg_temp.new_member_sql('00000000-0000-0000-0000-0000000000d2')), 'ok',
  'con override: miembro 6/6');
select is(pg_temp.err(pg_temp.new_member_sql('00000000-0000-0000-0000-0000000000d3')),
  'P0001|plan_limit_reached', 'con override: miembro 7 rechazado');
select pg_temp.logout();

-- -----------------------------------------------------------------------------
-- Etiquetas NFC (free: 10; hay 10)
-- -----------------------------------------------------------------------------
select pg_temp.login('00000000-0000-0000-0000-0000000000ed');
select is(pg_temp.err(pg_temp.new_tag_sql()), 'P0001|plan_limit_reached',
  'etiqueta NFC 11 → plan_limit_reached');
select throws_ok(pg_temp.new_tag_sql(), 'P0001',
  'Has alcanzado el límite de tu plan: máximo 10 etiquetas NFC', 'mensaje de etiquetas NFC');
select pg_temp.logout();

select pg_temp.login('00000000-0000-0000-0000-0000000000ff');
select is(pg_temp.err(pg_temp.new_tag_sql()), 'ok', 'platform admin exento (etiqueta 11)');
select lives_ok($$ update public.organizations set limits = '{"max_nfc_tags": 12}' where slug = 'org-a' $$,
  'platform admin fija override max_nfc_tags = 12');
select pg_temp.logout();

select pg_temp.login('00000000-0000-0000-0000-0000000000ed');
select is(pg_temp.err(pg_temp.new_tag_sql()), 'ok', 'con override: etiqueta 12/12');
select is(pg_temp.err(pg_temp.new_tag_sql()), 'P0001|plan_limit_reached',
  'con override: etiqueta 13 rechazada');
select pg_temp.logout();

-- -----------------------------------------------------------------------------
-- Logos (free: 5; enlaces 1..5 ya tienen logo)
-- -----------------------------------------------------------------------------
select pg_temp.set_limits('0000000a-0000-0000-0000-000000000000', '{}');
select pg_temp.login('00000000-0000-0000-0000-0000000000ed');
select is(pg_temp.err($$
  insert into public.qr_designs (link_id, org_id, logo_path, ecc_level)
  values ('a1000000-0000-0000-0000-000000000006', '0000000a-0000-0000-0000-000000000000',
          '0000000a-0000-0000-0000-000000000000/logo6.png', 'H') $$),
  'P0001|plan_limit_reached', 'diseño con logo nº 6 → plan_limit_reached');
select throws_ok($$
  insert into public.qr_designs (link_id, org_id, logo_path, ecc_level)
  values ('a1000000-0000-0000-0000-000000000006', '0000000a-0000-0000-0000-000000000000',
          '0000000a-0000-0000-0000-000000000000/logo6.png', 'H') $$,
  'P0001', 'Has alcanzado el límite de tu plan: máximo 5 logos', 'mensaje de logos');
select is(pg_temp.err($$
  insert into public.qr_designs (link_id, org_id)
  values ('a1000000-0000-0000-0000-000000000006', '0000000a-0000-0000-0000-000000000000') $$),
  'ok', 'un diseño sin logo no cuenta');
select is(pg_temp.err($$
  update public.qr_designs
     set logo_path = '0000000a-0000-0000-0000-000000000000/logo6.png', ecc_level = 'H'
   where link_id = 'a1000000-0000-0000-0000-000000000006' $$),
  'P0001|plan_limit_reached', 'añadir logo por UPDATE también cuenta');
select is(pg_temp.err($$
  insert into public.qr_designs (link_id, org_id, logo_path, ecc_level)
  values ('a1000000-0000-0000-0000-000000000001', '0000000a-0000-0000-0000-000000000000',
          '0000000a-0000-0000-0000-000000000000/logo1b.png', 'H')
  on conflict (link_id) do update set logo_path = excluded.logo_path $$),
  'ok', 'upsert que reemplaza el logo de un diseño que ya lo tenía: permitido');
select is(pg_temp.err($$
  insert into public.qr_designs (link_id, org_id, logo_path, ecc_level)
  values ('a1000000-0000-0000-0000-000000000006', '0000000a-0000-0000-0000-000000000000',
          '0000000a-0000-0000-0000-000000000000/logo6.png', 'H')
  on conflict (link_id) do update set logo_path = excluded.logo_path, ecc_level = 'H' $$),
  'P0001|plan_limit_reached', 'upsert que añade logo a un diseño sin logo: rechazado');
select lives_ok($$
  update public.qr_designs set logo_path = null
   where link_id = 'a1000000-0000-0000-0000-000000000002' $$,
  'quitar un logo libera hueco');
select is(pg_temp.err($$
  update public.qr_designs
     set logo_path = '0000000a-0000-0000-0000-000000000000/logo6.png', ecc_level = 'H'
   where link_id = 'a1000000-0000-0000-0000-000000000006' $$),
  'ok', 'tras liberar, se añade el logo');
select pg_temp.logout();

select pg_temp.login('00000000-0000-0000-0000-0000000000ff');
select is(pg_temp.err($$
  insert into public.qr_designs (link_id, org_id, logo_path, ecc_level)
  values ('a1000000-0000-0000-0000-000000000007', '0000000a-0000-0000-0000-000000000000',
          '0000000a-0000-0000-0000-000000000000/logo7.png', 'H') $$),
  'ok', 'platform admin exento (logo 6)');
select pg_temp.logout();

-- -----------------------------------------------------------------------------
-- create_organization: máximo 5 como owner
-- -----------------------------------------------------------------------------
select pg_temp.login('00000000-0000-0000-0000-0000000000c5');
select lives_ok($$ select public.create_organization('U ' || i, 'u5-org-' || i)
                   from generate_series(1, 5) i $$, 'u5 crea 5 organizaciones');
select is(pg_temp.err($$ select public.create_organization('U 6', 'u5-org-6') $$),
  'P0001|org_limit', 'la 6ª organización → P0001 org_limit');
select throws_ok($$ select public.create_organization('U 6', 'u5-org-6') $$, 'P0001',
  'Has alcanzado el máximo de 5 organizaciones propias', 'mensaje de org_limit');
select pg_temp.logout();

select pg_temp.login('00000000-0000-0000-0000-0000000000ff');
select lives_ok($$ select public.create_organization('P ' || i, 'pa-org-' || i)
                   from generate_series(1, 6) i $$, 'platform admin exento (6 organizaciones)');
select pg_temp.logout();

-- -----------------------------------------------------------------------------
-- Carrera: dos inserts concurrentes en la misma org con un solo hueco
-- -----------------------------------------------------------------------------
-- Conexión dblink a esta misma BD por la IP del servidor (scram; desde
-- localhost el hba es trust y dblink exige contraseña a no superusuarios).
create function pg_temp.connstr() returns text language sql as $$
  select format('host=%s port=%s dbname=%s user=postgres password=postgres',
                host(inet_server_addr()), inet_server_port(), current_database());
$$;

create function pg_temp.race_cleanup_sql() returns text language sql as $$
  select $q$
    delete from public.organizations where id = 'e0000000-0000-0000-0000-000000000053';
    delete from private.slug_registry where org_id = 'e0000000-0000-0000-0000-000000000053';
    delete from auth.users where id = '00000000-0000-0000-0000-000000000531';
  $q$;
$$;

create function pg_temp.race_session_sql() returns text language sql as $$
  select $q$
    set local role authenticated;
    set local request.jwt.claims to
      '{"sub": "00000000-0000-0000-0000-000000000531", "role": "authenticated"}';
  $q$;
$$;

create function pg_temp.race_insert_sql() returns text language sql as $$
  select $q$insert into public.dynamic_links (org_id, name, destination_url)
            values ('e0000000-0000-0000-0000-000000000053', 'race-t053', 'https://race.example.com/')$q$;
$$;

select dblink_connect('race_setup', pg_temp.connstr());
select dblink_exec('race_setup', pg_temp.race_cleanup_sql() || $q$
  insert into auth.users (id, email, aud, role) values
    ('00000000-0000-0000-0000-000000000531', 'race@test.local', 'authenticated', 'authenticated');
  insert into public.organizations (id, name, slug, limits) values
    ('e0000000-0000-0000-0000-000000000053', 'Race', 'race-t053', '{"max_links": 1}');
  insert into public.memberships (org_id, user_id, role) values
    ('e0000000-0000-0000-0000-000000000053', '00000000-0000-0000-0000-000000000531', 'owner');
$q$);

select dblink_connect('race1', pg_temp.connstr());
select dblink_connect('race2', pg_temp.connstr());
select dblink_exec('race1', 'begin');
select dblink_exec('race1', pg_temp.race_session_sql());
select dblink_exec('race2', 'begin');
select dblink_exec('race2', pg_temp.race_session_sql());

select is(dblink_exec('race1', pg_temp.race_insert_sql()), 'INSERT 0 1',
  'carrera: la sesión 1 inserta el único enlace permitido (sin confirmar)');
select is(dblink_send_query('race2', pg_temp.race_insert_sql()), 1,
  'carrera: la sesión 2 lanza su insert en paralelo');

-- Espera (máx. ~5 s) a que la sesión 2 quede bloqueada en el lock de la org.
create function pg_temp.wait_for_lock() returns boolean language plpgsql as $$
begin
  for i in 1..50 loop
    if exists (select 1 from pg_stat_activity
               where wait_event_type = 'Lock' and query like '%race-t053%') then
      return true;
    end if;
    perform pg_sleep(0.1);
  end loop;
  return false;
end $$;
select ok(pg_temp.wait_for_lock(), 'carrera: la sesión 2 espera el lock de la org');

select dblink_exec('race1', 'commit');
select is((select count(*)::int from dblink_get_result('race2', false) as t(status text)), 0,
  'carrera: el insert de la sesión 2 falla tras confirmar la 1');
select matches(dblink_error_message('race2'), 'máximo 1 enlaces',
  'carrera: la sesión 2 recibe plan_limit_reached');
select count(*) from dblink_get_result('race2', false) as t(status text);
select dblink_exec('race2', 'rollback');

select is(
  (select n from dblink('race_setup',
     $q$select count(*) from public.dynamic_links
        where org_id = 'e0000000-0000-0000-0000-000000000053'$q$) as t(n bigint)),
  1::bigint, 'carrera: solo queda 1 enlace (no se supera el límite)');

select dblink_exec('race_setup', pg_temp.race_cleanup_sql());
select dblink_disconnect('race1');
select dblink_disconnect('race2');
select dblink_disconnect('race_setup');

select * from finish(true);
rollback;
