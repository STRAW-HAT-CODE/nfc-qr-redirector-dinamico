-- DQR-T042 · Tests de link_breakdown y org_breakdown (pgTAP).
-- Ejecutar: supabase test db. Todo corre dentro de BEGIN … ROLLBACK: no deja datos.
begin;

create extension if not exists pgtap with schema extensions;

select plan(58);

-- La zona horaria de la sesión no debe influir: el día es siempre UTC.
set local timezone = 'America/Mexico_City';

-- -----------------------------------------------------------------------------
-- Helpers
-- -----------------------------------------------------------------------------
-- T = hoy UTC. d(n) = T - n. ts(n, 'HH:MI') = instante UTC de ese día.
create function pg_temp.d(p_n int) returns date language sql stable as $$
  select (now() at time zone 'UTC')::date - p_n
$$;
create function pg_temp.ts(p_n int, p_hm text) returns timestamptz language sql stable as $$
  select ((pg_temp.d(p_n))::text || ' ' || p_hm)::timestamp at time zone 'UTC'
$$;
create function pg_temp.h(p_c text) returns text language sql immutable as $$
  select repeat(p_c, 32)
$$;

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

-- Desglose de A1 en [T-2, T-1] (filas como int para comparar con VALUES).
create function pg_temp.lb(p_dim text)
returns table (value text, scans int, unique_visitors int)
language sql stable as $$
  select b.value, b.scans::int, b.unique_visitors::int
  from public.link_breakdown('a0000000-0000-0000-0000-000000000001',
                             pg_temp.d(2), pg_temp.d(1), p_dim) b
$$;
create function pg_temp.ob(p_org uuid, p_dim text)
returns table (value text, scans int, unique_visitors int)
language sql stable as $$
  select b.value, b.scans::int, b.unique_visitors::int
  from public.org_breakdown(p_org, pg_temp.d(2), pg_temp.d(1), p_dim) b
$$;

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
   'BrkA001', 'Link A1', 'https://a.example.com/'),
  ('a0000000-0000-0000-0000-000000000002', '0000000a-0000-0000-0000-000000000000',
   'BrkA002', 'Link A2', 'https://a.example.com/2'),
  ('b0000000-0000-0000-0000-000000000001', '0000000b-0000-0000-0000-000000000000',
   'BrkB001', 'Link B1', 'https://b.example.com/');

-- A1 (detalle). Rango de prueba [T-2, T-1].
--   T-1: 1-2 qr MX mobile iOS Safari ig h1 (mismo visitante dos veces)
--        3   nfc US desktop macOS Chrome — h2
--        4   direct, todo NULL, sin ip_hash
--        5   qr MX device 'other' (literal) Android Chrome ig h3
--        bots: qr MX bot h9 · nfc ZZ h8 (no cuentan)
--   T-2: 6   qr MX mobile iOS Safari ig h1 (mismo hash, otro día → otro único)
--   Fuera de rango: T-5 qr MX h5 · T 00:00 qr MX h1
insert into public.scan_events
  (link_id, org_id, channel, occurred_at, country, device, os, browser, referer, ip_hash, is_bot)
select 'a0000000-0000-0000-0000-000000000001', '0000000a-0000-0000-0000-000000000000',
       c::public.scan_channel, pg_temp.ts(n, hm), co, dv, os, br, rf, ih, b
from (values
  ('qr',     1, '10:00', 'MX', 'mobile',  'iOS',     'Safari', 'https://ig.com', pg_temp.h('1'), false),
  ('qr',     1, '11:00', 'MX', 'mobile',  'iOS',     'Safari', 'https://ig.com', pg_temp.h('1'), false),
  ('nfc',    1, '12:00', 'US', 'desktop', 'macOS',   'Chrome', null,             pg_temp.h('2'), false),
  ('direct', 1, '13:00', null, null,      null,      null,     null,             null,           false),
  ('qr',     1, '23:59', 'MX', 'other',   'Android', 'Chrome', 'https://ig.com', pg_temp.h('3'), false),
  ('qr',     1, '14:00', 'MX', 'bot',     null,      null,     'https://ig.com', pg_temp.h('9'), true),
  ('nfc',    1, '15:00', 'ZZ', 'bot',     null,      null,     'https://bot.example', pg_temp.h('8'), true),
  ('qr',     2, '00:00', 'MX', 'mobile',  'iOS',     'Safari', 'https://ig.com', pg_temp.h('1'), false),
  ('qr',     5, '10:00', 'MX', 'mobile',  'iOS',     'Safari', 'https://ig.com', pg_temp.h('5'), false),
  ('qr',     0, '00:00', 'MX', 'mobile',  'iOS',     'Safari', 'https://ig.com', pg_temp.h('1'), false)
) as v(c, n, hm, co, dv, os, br, rf, ih, b);

-- A2 (volumen para top 20 / other), todo en T-1, canal qr, device 'other':
--   país i (i = 1..25, código chr(64+i)||'Q': AQ..YQ) con i escaneos, cada
--   uno con un ip_hash distinto → únicos = escaneos. 325 escaneos.
--   + 2 escaneos con país NULL y sin ip_hash. os: 'unknown' literal si i ≤ 10,
--   NULL en el resto → todo cae en 'unknown'.
insert into public.scan_events
  (link_id, org_id, channel, occurred_at, country, device, os, ip_hash)
select 'a0000000-0000-0000-0000-000000000002', '0000000a-0000-0000-0000-000000000000',
       'qr', pg_temp.ts(1, '09:00'), chr(64 + i) || 'Q', 'other',
       case when i <= 10 then 'unknown' end,
       md5(i::text || '-' || j::text)
from generate_series(1, 25) i, generate_series(1, 25) j
where j <= i;
insert into public.scan_events
  (link_id, org_id, channel, occurred_at, country, device, os, ip_hash)
values
  ('a0000000-0000-0000-0000-000000000002', '0000000a-0000-0000-0000-000000000000',
   'qr', pg_temp.ts(1, '09:30'), null, 'other', null, null),
  ('a0000000-0000-0000-0000-000000000002', '0000000a-0000-0000-0000-000000000000',
   'qr', pg_temp.ts(1, '09:31'), null, 'other', null, null);

-- B1: T-1 qr MX h1 (no debe sumarse a A).
insert into public.scan_events
  (link_id, org_id, channel, occurred_at, country, device, ip_hash)
values ('b0000000-0000-0000-0000-000000000001', '0000000b-0000-0000-0000-000000000000',
        'qr', pg_temp.ts(1, '10:00'), 'MX', 'mobile', pg_temp.h('1'));

-- -----------------------------------------------------------------------------
-- Definición y privilegios
-- -----------------------------------------------------------------------------
select ok(not (select prosecdef from pg_proc where oid = 'public.link_breakdown(uuid, date, date, text)'::regprocedure),
  'link_breakdown es SECURITY INVOKER');
select ok(not (select prosecdef from pg_proc where oid = 'public.org_breakdown(uuid, date, date, text)'::regprocedure),
  'org_breakdown es SECURITY INVOKER');
select is(
  (select count(*)::int from pg_proc
   where oid in ('public.link_breakdown(uuid, date, date, text)'::regprocedure,
                 'public.org_breakdown(uuid, date, date, text)'::regprocedure)
     and provolatile = 's' and proconfig @> array['search_path=""']),
  2, 'ambas son STABLE con search_path vacío');
select ok(has_function_privilege('authenticated', 'public.link_breakdown(uuid, date, date, text)', 'execute'),
  'authenticated puede ejecutar link_breakdown');
select ok(has_function_privilege('authenticated', 'public.org_breakdown(uuid, date, date, text)', 'execute'),
  'authenticated puede ejecutar org_breakdown');
select ok(not has_function_privilege('anon', 'public.link_breakdown(uuid, date, date, text)', 'execute'),
  'anon no puede ejecutar link_breakdown');
select ok(not has_function_privilege('anon', 'public.org_breakdown(uuid, date, date, text)', 'execute'),
  'anon no puede ejecutar org_breakdown');

-- -----------------------------------------------------------------------------
-- link_breakdown: cada dimensión (a1, owner de A)
-- -----------------------------------------------------------------------------
select pg_temp.login('00000000-0000-0000-0000-0000000000a1');

select results_eq(
  $$ select * from pg_temp.lb('country') $$,
  $$ values ('MX', 4, 3), ('US', 1, 1), ('unknown', 1, 0) $$,
  'country: bots fuera, rango [T-2, T-1], únicos por día, NULL → unknown');
select results_eq(
  $$ select * from pg_temp.lb('device') $$,
  $$ values ('mobile', 3, 2), ('desktop', 1, 1), ('unknown', 1, 0), ('other', 1, 1) $$,
  'device: el valor literal other va a la fila other, al final');
select results_eq(
  $$ select * from pg_temp.lb('os') $$,
  $$ values ('iOS', 3, 2), ('Android', 1, 1), ('macOS', 1, 1), ('unknown', 1, 0) $$,
  'os: empate de escaneos resuelto por valor (collation C)');
select results_eq(
  $$ select * from pg_temp.lb('browser') $$,
  $$ values ('Safari', 3, 2), ('Chrome', 2, 2), ('unknown', 1, 0) $$,
  'browser');
select results_eq(
  $$ select * from pg_temp.lb('channel') $$,
  $$ values ('qr', 4, 3), ('direct', 1, 0), ('nfc', 1, 1) $$,
  'channel');
select results_eq(
  $$ select * from pg_temp.lb('referer') $$,
  $$ values ('https://ig.com', 4, 3), ('unknown', 2, 1) $$,
  'referer');

select is(
  (select sum(scans)::int from pg_temp.lb('country')), 6,
  'la suma de escaneos del desglose = escaneos humanos del rango');
select ok(
  not exists (select 1 from pg_temp.lb('country') where value = 'ZZ'),
  'un valor que solo tienen bots no aparece');
select ok(
  not exists (select 1 from pg_temp.lb('device') where value = 'bot'),
  'device bot no aparece');
select ok(
  not exists (select 1 from pg_temp.lb('country') where value = 'other'),
  'sin resto no hay fila other');

select results_eq(
  $$ select b.value, b.scans::int, b.unique_visitors::int
     from public.link_breakdown('a0000000-0000-0000-0000-000000000001',
                                pg_temp.d(0), pg_temp.d(0), 'country') b $$,
  $$ values ('MX', 1, 1) $$,
  'el escaneo de las 00:00 UTC cuenta en su día UTC, no en el local');
select results_eq(
  $$ select b.value, b.scans::int
     from public.link_breakdown('a0000000-0000-0000-0000-000000000001',
                                pg_temp.d(5), pg_temp.d(0), 'channel') b $$,
  $$ values ('qr', 6), ('direct', 1), ('nfc', 1) $$,
  'un rango más amplio incluye T-5 y hoy');

-- Tipos de salida
select is(
  (select pg_typeof(b.scans)::text || ',' || pg_typeof(b.unique_visitors)::text
   from public.link_breakdown('a0000000-0000-0000-0000-000000000001',
                              pg_temp.d(2), pg_temp.d(1), 'channel') b limit 1),
  'bigint,bigint', 'scans y unique_visitors son bigint');

-- -----------------------------------------------------------------------------
-- Top 20 + other (A2)
-- -----------------------------------------------------------------------------
select is(
  (select count(*)::int
   from public.link_breakdown('a0000000-0000-0000-0000-000000000002',
                              pg_temp.d(1), pg_temp.d(1), 'country')),
  21, 'A2 country: 20 valores + other');
select results_eq(
  $$ select b.value, b.scans::int, b.unique_visitors::int
     from public.link_breakdown('a0000000-0000-0000-0000-000000000002',
                                pg_temp.d(1), pg_temp.d(1), 'country') b
     limit 3 $$,
  $$ values ('YQ', 25, 25), ('XQ', 24, 24), ('WQ', 23, 23) $$,
  'A2 country: ordenado de mayor a menor');
select results_eq(
  $$ select b.value, b.scans::int, b.unique_visitors::int
     from public.link_breakdown('a0000000-0000-0000-0000-000000000002',
                                pg_temp.d(1), pg_temp.d(1), 'country') b
     offset 19 $$,
  $$ values ('FQ', 6, 6), ('other', 17, 15) $$,
  'A2 country: el 20.º es FQ (6) y other = AQ..EQ (15) + unknown (2, sin únicos)');
select is(
  (select sum(scans)::int
   from public.link_breakdown('a0000000-0000-0000-0000-000000000002',
                              pg_temp.d(1), pg_temp.d(1), 'country')),
  327, 'A2 country: el total se conserva');
select results_eq(
  $$ select b.value, b.scans::int
     from public.link_breakdown('a0000000-0000-0000-0000-000000000002',
                                pg_temp.d(1), pg_temp.d(1), 'os') b $$,
  $$ values ('unknown', 327) $$,
  'A2 os: unknown literal y NULL se juntan en una sola fila unknown');
select results_eq(
  $$ select b.value, b.scans::int
     from public.link_breakdown('a0000000-0000-0000-0000-000000000002',
                                pg_temp.d(1), pg_temp.d(1), 'device') b $$,
  $$ values ('other', 327) $$,
  'A2 device: solo el literal other → una única fila other');

-- -----------------------------------------------------------------------------
-- org_breakdown
-- -----------------------------------------------------------------------------
select results_eq(
  $$ select * from pg_temp.ob('0000000a-0000-0000-0000-000000000000', 'channel') $$,
  $$ values ('qr', 331, 328), ('direct', 1, 0), ('nfc', 1, 1) $$,
  'org A channel: suma A1 + A2, sin B ni bots');
select is(
  (select count(*)::int from pg_temp.ob('0000000a-0000-0000-0000-000000000000', 'country')),
  21, 'org A country: 20 valores + other');
select results_eq(
  $$ select * from pg_temp.ob('0000000a-0000-0000-0000-000000000000', 'country') offset 19 $$,
  $$ values ('FQ', 6, 6), ('other', 23, 19) $$,
  'org A country: other = AQ..EQ (15) + MX (4) + US (1) + unknown (3)');
select results_eq(
  $$ select * from pg_temp.ob('0000000a-0000-0000-0000-000000000000', 'device') $$,
  $$ values ('mobile', 3, 2), ('desktop', 1, 1), ('unknown', 1, 0), ('other', 328, 326) $$,
  'org A device');
select results_eq(
  $$ select * from pg_temp.ob('0000000b-0000-0000-0000-000000000000', 'country') $$,
  $$ select 'MX'::text, 0, 0 where false $$,
  'org B no es visible para a1');
select is(
  (select count(*)::int from public.link_breakdown('b0000000-0000-0000-0000-000000000001',
     pg_temp.d(2), pg_temp.d(1), 'country')),
  0, 'link_breakdown de B para a1: 0 filas');

-- Viewer de A
select pg_temp.logout();
select pg_temp.login('00000000-0000-0000-0000-0000000000a2');
select results_eq(
  $$ select * from pg_temp.lb('channel') $$,
  $$ values ('qr', 4, 3), ('direct', 1, 0), ('nfc', 1, 1) $$,
  'viewer de A ve el desglose del enlace');
select is(
  (select count(*)::int from pg_temp.ob('0000000a-0000-0000-0000-000000000000', 'channel')),
  3, 'viewer de A ve el desglose de la org');

-- -----------------------------------------------------------------------------
-- Aislamiento A/B
-- -----------------------------------------------------------------------------
select pg_temp.logout();
select pg_temp.login('00000000-0000-0000-0000-0000000000b1');
select is((select count(*)::int from pg_temp.lb('country')), 0,
  'b1: link_breakdown de A → 0 filas');
select is((select count(*)::int from pg_temp.ob('0000000a-0000-0000-0000-000000000000', 'country')), 0,
  'b1: org_breakdown de A → 0 filas');
select results_eq(
  $$ select * from pg_temp.ob('0000000b-0000-0000-0000-000000000000', 'country') $$,
  $$ values ('MX', 1, 1) $$,
  'b1 ve solo lo de B');
select results_eq(
  $$ select b.value, b.scans::int, b.unique_visitors::int
     from public.link_breakdown('b0000000-0000-0000-0000-000000000001',
                                pg_temp.d(2), pg_temp.d(1), 'device') b $$,
  $$ values ('mobile', 1, 1) $$,
  'b1 ve el desglose de su enlace');

select pg_temp.logout();
select pg_temp.login('00000000-0000-0000-0000-0000000000cc');
select is((select count(*)::int from pg_temp.lb('channel')), 0,
  'usuario sin org: link_breakdown → 0 filas');
select is((select count(*)::int from pg_temp.ob('0000000a-0000-0000-0000-000000000000', 'channel')), 0,
  'usuario sin org: org_breakdown → 0 filas');

-- Guarda (sec-T041 H1): el extraño no llega a leer scan_events
-- (contadores de la transacción en curso).
select pg_temp.logout();
create temp table guard_probe as
  select seq_scan + coalesce(idx_scan, 0) as n
  from pg_stat_xact_user_tables where relid = 'public.scan_events'::regclass;
select pg_temp.login('00000000-0000-0000-0000-0000000000cc');
select count(*) from public.org_breakdown('0000000a-0000-0000-0000-000000000000',
  pg_temp.d(365), pg_temp.d(0), 'country');
select count(*) from public.link_breakdown('a0000000-0000-0000-0000-000000000001',
  pg_temp.d(365), pg_temp.d(0), 'country');
select pg_temp.logout();
select is(
  (select seq_scan + coalesce(idx_scan, 0)
   from pg_stat_xact_user_tables where relid = 'public.scan_events'::regclass),
  (select n from guard_probe),
  'guarda: un extraño no provoca ningún escaneo de scan_events');

-- Platform admin
select pg_temp.login('00000000-0000-0000-0000-0000000000ff');
select results_eq(
  $$ select * from pg_temp.lb('channel') $$,
  $$ values ('qr', 4, 3), ('direct', 1, 0), ('nfc', 1, 1) $$,
  'platform admin ve el desglose de un enlace de A');
select is(
  (select count(*)::int from pg_temp.ob('0000000b-0000-0000-0000-000000000000', 'country')),
  1, 'platform admin ve el desglose de B');

-- -----------------------------------------------------------------------------
-- Validación (como a1)
-- -----------------------------------------------------------------------------
select pg_temp.logout();
select pg_temp.login('00000000-0000-0000-0000-0000000000a1');

select throws_ok(
  $$ select * from public.link_breakdown('a0000000-0000-0000-0000-000000000001',
       pg_temp.d(1), pg_temp.d(1), 'ip_hash') $$,
  '22023', 'link_breakdown: dimensión no válida', 'link: dimensión fuera de la lista → 22023');
select throws_ok(
  $$ select * from public.link_breakdown('a0000000-0000-0000-0000-000000000001',
       pg_temp.d(1), pg_temp.d(1), 'country; select 1') $$,
  '22023', 'link_breakdown: dimensión no válida', 'link: inyección en la dimensión → 22023');
select throws_ok(
  $$ select * from public.link_breakdown('a0000000-0000-0000-0000-000000000001',
       pg_temp.d(1), pg_temp.d(1), null) $$,
  '22023', 'link_breakdown: dimensión no válida', 'link: dimensión nula → 22023');
select throws_ok(
  $$ select * from public.org_breakdown('0000000a-0000-0000-0000-000000000000',
       pg_temp.d(1), pg_temp.d(1), 'Country') $$,
  '22023', 'org_breakdown: dimensión no válida', 'org: la dimensión distingue mayúsculas → 22023');
select throws_ok(
  $$ select * from public.org_breakdown('0000000b-0000-0000-0000-000000000000',
       pg_temp.d(1), pg_temp.d(1), 'ip_hash') $$,
  '22023', 'org_breakdown: dimensión no válida', 'org: valida antes de la guarda (también si no es miembro)');

select throws_ok(
  $$ select * from public.link_breakdown('a0000000-0000-0000-0000-000000000001',
       pg_temp.d(0), pg_temp.d(1), 'country') $$,
  '22023', 'link_breakdown: rango no válido (máximo 366 días)', 'link: from > to → 22023');
select throws_ok(
  $$ select * from public.link_breakdown('a0000000-0000-0000-0000-000000000001',
       pg_temp.d(366), pg_temp.d(0), 'country') $$,
  '22023', 'link_breakdown: rango no válido (máximo 366 días)', 'link: 367 días → 22023');
select lives_ok(
  $$ select * from public.link_breakdown('a0000000-0000-0000-0000-000000000001',
       pg_temp.d(365), pg_temp.d(0), 'country') $$,
  'link: 366 días se aceptan');
select throws_ok(
  $$ select * from public.link_breakdown('a0000000-0000-0000-0000-000000000001',
       null, pg_temp.d(0), 'country') $$,
  '22023', 'link_breakdown: rango no válido (máximo 366 días)', 'link: from nulo → 22023');
select throws_ok(
  $$ select * from public.link_breakdown(null, pg_temp.d(1), pg_temp.d(0), 'country') $$,
  '22023', 'link_breakdown: rango no válido (máximo 366 días)', 'link: enlace nulo → 22023');
select throws_ok(
  $$ select * from public.org_breakdown('0000000a-0000-0000-0000-000000000000',
       pg_temp.d(0), pg_temp.d(1), 'country') $$,
  '22023', 'org_breakdown: rango no válido (máximo 366 días)', 'org: from > to → 22023');
select throws_ok(
  $$ select * from public.org_breakdown('0000000a-0000-0000-0000-000000000000',
       pg_temp.d(366), pg_temp.d(0), 'country') $$,
  '22023', 'org_breakdown: rango no válido (máximo 366 días)', 'org: 367 días → 22023');
select throws_ok(
  $$ select * from public.org_breakdown('0000000a-0000-0000-0000-000000000000',
       '-infinity'::date, pg_temp.d(0), 'country') $$,
  '22023', 'org_breakdown: rango no válido (máximo 366 días)', 'org: -infinity → 22023');
select throws_ok(
  $$ select * from public.link_breakdown('a0000000-0000-0000-0000-000000000001',
       pg_temp.d(0), 'infinity'::date, 'country') $$,
  '22023', 'link_breakdown: rango no válido (máximo 366 días)', 'link: infinity → 22023');

select pg_temp.logout();

-- anon no puede llamarlas
set local role anon;
select throws_ok(
  $$ select * from public.org_breakdown('0000000a-0000-0000-0000-000000000000',
       current_date, current_date, 'country') $$,
  '42501', null, 'anon: org_breakdown → 42501');
reset role;

select * from finish();
rollback;
