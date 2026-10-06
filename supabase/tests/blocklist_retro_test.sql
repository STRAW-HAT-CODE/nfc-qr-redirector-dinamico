-- DQR-T057-N1 · Tests de la blocklist retroactiva (pgTAP).
-- Ejecutar: supabase test db (o psql -f). Todo dentro de BEGIN … ROLLBACK.
begin;

create extension if not exists pgtap with schema extensions;

select plan(35);

-- -----------------------------------------------------------------------------
-- Fixtures (como postgres). Los enlaces se crean ANTES de bloquear el dominio.
-- -----------------------------------------------------------------------------
-- Org A: o1 owner. Org B: ob owner. pa platform admin. u5 sin org.
insert into auth.users (id, email, aud, role) values
  ('00000000-0000-0000-0000-0000000000a1', 'o1@test.local', 'authenticated', 'authenticated'),
  ('00000000-0000-0000-0000-0000000000b1', 'ob@test.local', 'authenticated', 'authenticated'),
  ('00000000-0000-0000-0000-0000000000ff', 'pa@test.local', 'authenticated', 'authenticated'),
  ('00000000-0000-0000-0000-0000000000c5', 'u5@test.local', 'authenticated', 'authenticated');

insert into public.platform_admins (user_id) values ('00000000-0000-0000-0000-0000000000ff');

insert into public.organizations (id, name, slug) values
  ('0000000a-0000-0000-0000-000000000000', 'Org A', 'org-a-t057'),
  ('0000000b-0000-0000-0000-000000000000', 'Org B', 'org-b-t057');

insert into public.memberships (org_id, user_id, role) values
  ('0000000a-0000-0000-0000-000000000000', '00000000-0000-0000-0000-0000000000a1', 'owner'),
  ('0000000b-0000-0000-0000-000000000000', '00000000-0000-0000-0000-0000000000b1', 'owner');

-- L1: destino en el dominio · L2: fallback en un subdominio · L3: limpio ·
-- L4 (org B): destino con mayúsculas y puerto · L5: dominio hermano (no bloqueado).
insert into public.dynamic_links (id, org_id, slug, name, destination_url, fallback_url) values
  ('b1000000-0000-0000-0000-000000000001', '0000000a-0000-0000-0000-000000000000',
   'Blk0001', 'L1', 'https://evil.example.com/a', null),
  ('b1000000-0000-0000-0000-000000000002', '0000000a-0000-0000-0000-000000000000',
   'Blk0002', 'L2', 'https://ok.example.net/', 'https://sub.evil.example.com/fb'),
  ('b1000000-0000-0000-0000-000000000003', '0000000a-0000-0000-0000-000000000000',
   'Blk0003', 'L3', 'https://ok.example.net/3', 'https://fb.example.net/'),
  ('b1000000-0000-0000-0000-000000000004', '0000000b-0000-0000-0000-000000000000',
   'Blk0004', 'L4', 'https://WWW.EVIL.example.com:8443/x', null),
  ('b1000000-0000-0000-0000-000000000005', '0000000a-0000-0000-0000-000000000000',
   'Blk0005', 'L5', 'https://notevil.example.com/', null);

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
-- Catálogo
-- -----------------------------------------------------------------------------
select ok(
  (select p.prosecdef and p.provolatile = 's' and p.proconfig = array['search_path=""']
     from pg_proc p where p.oid = 'public.resolve_link(text)'::regprocedure),
  'resolve_link: SECURITY DEFINER, STABLE y search_path vacío');
select ok(
  has_function_privilege('service_role', 'public.resolve_link(text)', 'execute')
  and not has_function_privilege('authenticated', 'public.resolve_link(text)', 'execute')
  and not has_function_privilege('anon', 'public.resolve_link(text)', 'execute'),
  'resolve_link: EXECUTE solo service_role');
select ok(
  (select p.prosecdef and p.proconfig = array['search_path=""']
     from pg_proc p where p.oid = 'public.admin_list_blocked_links(int)'::regprocedure),
  'admin_list_blocked_links: SECURITY DEFINER y search_path vacío');
select ok(
  has_function_privilege('authenticated', 'public.admin_list_blocked_links(int)', 'execute')
  and not has_function_privilege('anon', 'public.admin_list_blocked_links(int)', 'execute')
  and not has_function_privilege('service_role', 'public.admin_list_blocked_links(int)', 'execute'),
  'admin_list_blocked_links: EXECUTE solo authenticated');

-- -----------------------------------------------------------------------------
-- Antes de bloquear
-- -----------------------------------------------------------------------------
set local role service_role;
select is((select r.destination_blocked from public.resolve_link('Blk0001') r), false,
  'antes de bloquear: destination_blocked = false');
select is((select r.fallback_url from public.resolve_link('Blk0002') r), 'https://sub.evil.example.com/fb',
  'antes de bloquear: el fallback llega tal cual');
reset role;

select pg_temp.login('00000000-0000-0000-0000-0000000000ff');
select is((select count(*) from public.admin_list_blocked_links()), 0::bigint,
  'antes de bloquear: ningún enlace afectado');
select lives_ok($$select public.admin_block_domain('evil.example.com')$$,
  'el platform admin bloquea evil.example.com');
select pg_temp.logout();

-- -----------------------------------------------------------------------------
-- resolve_link (redirector) tras bloquear
-- -----------------------------------------------------------------------------
set local role service_role;
select is((select r.destination_blocked from public.resolve_link('Blk0001') r), true,
  'enlace existente con destino bloqueado → destination_blocked = true');
select is((select r.destination_blocked from public.resolve_link('Blk0004') r), true,
  'subdominio, mayúsculas y puerto → destination_blocked = true');
select is((select r.destination_blocked from public.resolve_link('Blk0005') r), false,
  'dominio hermano (notevil.example.com) → false');
select is(
  (select row(r.destination_blocked, r.fallback_url)::text from public.resolve_link('Blk0002') r),
  row(false, null::text)::text,
  'fallback bloqueado → destination_blocked = false y fallback_url NULL');
select results_eq(
  $$ select id, org_id, destination_url, fallback_url, status, starts_at, expires_at,
            org_status, suspended_at, destination_blocked
     from public.resolve_link('Blk0003') $$,
  $$ values ('b1000000-0000-0000-0000-000000000003'::uuid, '0000000a-0000-0000-0000-000000000000'::uuid,
             'https://ok.example.net/3'::text, 'https://fb.example.net/'::text,
             'active'::public.link_status, null::timestamptz, null::timestamptz,
             'active'::public.org_status, null::timestamptz, false) $$,
  'enlace limpio: todas las columnas, fallback intacto');
select is((select count(*)::int from public.resolve_link('NoExist')), 0,
  'slug inexistente → sin filas');
reset role;

select is(
  (select fallback_url from public.dynamic_links where id = 'b1000000-0000-0000-0000-000000000002'),
  'https://sub.evil.example.com/fb', 'el fallback guardado no cambia');

set local role anon;
select throws_ok($$select * from public.resolve_link('Blk0001')$$, '42501', null,
  'anon no ejecuta resolve_link');
reset role;
select pg_temp.login('00000000-0000-0000-0000-0000000000a1');
select throws_ok($$select * from public.resolve_link('Blk0001')$$, '42501', null,
  'authenticated no ejecuta resolve_link');

-- -----------------------------------------------------------------------------
-- admin_list_blocked_links
-- -----------------------------------------------------------------------------
select throws_ok($$select * from public.admin_list_blocked_links()$$, '42501', null,
  'owner: admin_list_blocked_links → 42501');
select pg_temp.logout();

select pg_temp.login('00000000-0000-0000-0000-0000000000c5');
select throws_ok($$select * from public.admin_list_blocked_links()$$, '42501', null,
  'sin org: admin_list_blocked_links → 42501');
select pg_temp.logout();

set local role service_role;
select throws_ok($$select * from public.admin_list_blocked_links()$$, '42501', null,
  'service_role: admin_list_blocked_links → 42501 (sin EXECUTE)');
reset role;

select pg_temp.login('00000000-0000-0000-0000-0000000000ff');
select is(
  array(select l.id from public.admin_list_blocked_links() l),
  array['b1000000-0000-0000-0000-000000000001'::uuid,
        'b1000000-0000-0000-0000-000000000002'::uuid,
        'b1000000-0000-0000-0000-000000000004'::uuid],
  'lista destino y fallback bloqueados de todas las orgs (orden created_at desc, id)');
select is(
  (select row(l.org_name, l.slug, l.destination_blocked, l.fallback_blocked)::text
     from public.admin_list_blocked_links() l where l.id = 'b1000000-0000-0000-0000-000000000001'),
  row('Org A', 'Blk0001', true, false)::text, 'L1: destino bloqueado');
select is(
  (select row(l.fallback_url, l.destination_blocked, l.fallback_blocked)::text
     from public.admin_list_blocked_links() l where l.id = 'b1000000-0000-0000-0000-000000000002'),
  row('https://sub.evil.example.com/fb', false, true)::text,
  'L2: fallback bloqueado (muestra la URL guardada)');
select is(
  (select l.org_name from public.admin_list_blocked_links() l
    where l.id = 'b1000000-0000-0000-0000-000000000004'),
  'Org B', 'L4: enlace de otra org');
select is((select count(*) from public.admin_list_blocked_links(1)), 1::bigint, 'limit 1');
select is((select count(*) from public.admin_list_blocked_links(0)), 1::bigint, 'limit 0 se acota a 1');
select is((select count(*) from public.admin_list_blocked_links(null)), 3::bigint, 'limit NULL → 100');

-- Suspender desde la consola: sigue en la lista con suspended_at.
select lives_ok(
  $$select public.admin_suspend_link('b1000000-0000-0000-0000-000000000001', true, 'Dominio bloqueado')$$,
  'el platform admin suspende L1');
select isnt(
  (select l.suspended_at from public.admin_list_blocked_links() l
    where l.id = 'b1000000-0000-0000-0000-000000000001'),
  null::timestamptz, 'la lista muestra suspended_at');

-- Desbloquear revierte el efecto.
select lives_ok($$select public.admin_unblock_domain('evil.example.com')$$,
  'el platform admin desbloquea evil.example.com');
select is((select count(*) from public.admin_list_blocked_links()), 0::bigint,
  'tras desbloquear: ningún enlace afectado');
select pg_temp.logout();

set local role service_role;
select is((select r.destination_blocked from public.resolve_link('Blk0004') r), false,
  'tras desbloquear: destination_blocked = false');
select is((select r.fallback_url from public.resolve_link('Blk0002') r), 'https://sub.evil.example.com/fb',
  'tras desbloquear: vuelve el fallback');
select isnt((select r.suspended_at from public.resolve_link('Blk0001') r), null::timestamptz,
  'la suspensión es independiente de la blocklist');
reset role;

-- Bloquear un dominio padre afecta a todos sus subdominios.
insert into private.blocked_domains (domain) values ('example.com');
set local role service_role;
select is(
  (select count(*) from unnest(array['Blk0001', 'Blk0004', 'Blk0005']) s
    cross join lateral public.resolve_link(s) r where r.destination_blocked),
  3::bigint, 'bloquear example.com bloquea evil., www.evil. y notevil.example.com');
reset role;

select * from finish(true);
rollback;
