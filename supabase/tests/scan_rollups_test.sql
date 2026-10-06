-- DQR-T041 · Tests de scan_daily_rollups, refresh_scan_rollups, link_stats y org_stats (pgTAP).
-- Ejecutar: supabase test db. Todo corre dentro de BEGIN … ROLLBACK: no deja datos.
begin;

create extension if not exists pgtap with schema extensions;

select plan(86);

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

create function pg_temp.set_closed(p_day date) returns void language sql as $$
  update private.scan_rollup_state set closed_through = p_day where id
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
   'RollA01', 'Link A1', 'https://a.example.com/'),
  ('a0000000-0000-0000-0000-000000000002', '0000000a-0000-0000-0000-000000000000',
   'RollA02', 'Link A2', 'https://a.example.com/2'),
  ('b0000000-0000-0000-0000-000000000001', '0000000b-0000-0000-0000-000000000000',
   'RollB01', 'Link B1', 'https://b.example.com/');

-- Eventos. A1 = a…01, A2 = a…02, B1 = b…01.
--   A1 T-2: qr h1, qr h1, qr h2, nfc h3, direct NULL (humanos) + 2 bots (h9)
--   A1 T-3: solo un bot
--   A1 T  : qr h1 (00:00 UTC = ayer en México), qr h2 + 1 bot
--   A2 T-2: direct h1
--   B1 T-2: qr h1, qr h4
insert into public.scan_events (link_id, org_id, channel, occurred_at, ip_hash, is_bot)
select l::uuid, o::uuid, c::public.scan_channel, pg_temp.ts(n, hm), ih, b
from (values
  ('a0000000-0000-0000-0000-000000000001', '0000000a-0000-0000-0000-000000000000', 'qr',     2, '10:00', pg_temp.h('1'), false),
  ('a0000000-0000-0000-0000-000000000001', '0000000a-0000-0000-0000-000000000000', 'qr',     2, '11:00', pg_temp.h('1'), false),
  ('a0000000-0000-0000-0000-000000000001', '0000000a-0000-0000-0000-000000000000', 'qr',     2, '12:00', pg_temp.h('2'), false),
  ('a0000000-0000-0000-0000-000000000001', '0000000a-0000-0000-0000-000000000000', 'nfc',    2, '13:00', pg_temp.h('3'), false),
  ('a0000000-0000-0000-0000-000000000001', '0000000a-0000-0000-0000-000000000000', 'direct', 2, '23:59', null,           false),
  ('a0000000-0000-0000-0000-000000000001', '0000000a-0000-0000-0000-000000000000', 'qr',     2, '14:00', pg_temp.h('9'), true),
  ('a0000000-0000-0000-0000-000000000001', '0000000a-0000-0000-0000-000000000000', 'direct', 2, '15:00', pg_temp.h('9'), true),
  ('a0000000-0000-0000-0000-000000000001', '0000000a-0000-0000-0000-000000000000', 'qr',     3, '10:00', pg_temp.h('9'), true),
  ('a0000000-0000-0000-0000-000000000001', '0000000a-0000-0000-0000-000000000000', 'qr',     0, '00:00', pg_temp.h('1'), false),
  ('a0000000-0000-0000-0000-000000000001', '0000000a-0000-0000-0000-000000000000', 'qr',     0, '00:01', pg_temp.h('2'), false),
  ('a0000000-0000-0000-0000-000000000001', '0000000a-0000-0000-0000-000000000000', 'nfc',    0, '00:02', pg_temp.h('9'), true),
  ('a0000000-0000-0000-0000-000000000002', '0000000a-0000-0000-0000-000000000000', 'direct', 2, '10:00', pg_temp.h('1'), false),
  ('b0000000-0000-0000-0000-000000000001', '0000000b-0000-0000-0000-000000000000', 'qr',     2, '10:00', pg_temp.h('1'), false),
  ('b0000000-0000-0000-0000-000000000001', '0000000b-0000-0000-0000-000000000000', 'qr',     2, '10:00', pg_temp.h('4'), false)
) as v(l, o, c, n, hm, ih, b);

-- Partimos de una tabla de rollups vacía para el rango de los fixtures.
delete from public.scan_daily_rollups;

-- -----------------------------------------------------------------------------
-- Esquema, índices y privilegios
-- -----------------------------------------------------------------------------
select has_table('public', 'scan_daily_rollups', 'existe scan_daily_rollups');
select ok((select relrowsecurity from pg_class where oid = 'public.scan_daily_rollups'::regclass),
  'RLS habilitado en scan_daily_rollups');
select col_is_pk('public', 'scan_daily_rollups', array['link_id', 'day'], 'PK (link_id, day)');
select fk_ok('public', 'scan_daily_rollups', array['link_id', 'org_id'],
             'public', 'dynamic_links', array['id', 'org_id'],
  'FK compuesta (link_id, org_id) → dynamic_links (id, org_id)');
select ok(
  (select confdeltype = 'c' from pg_constraint where conname = 'scan_daily_rollups_link_org_fkey'),
  'la FK borra en cascada');
select has_index('public', 'scan_daily_rollups', 'scan_daily_rollups_org_day_idx',
  array['org_id', 'day'], 'índice (org_id, day)');
select has_index('public', 'scan_daily_rollups', 'scan_daily_rollups_day_idx',
  array['day'], 'índice (day)');

select ok((select prosecdef from pg_proc where oid = 'private.refresh_scan_rollups(date, date)'::regprocedure),
  'refresh_scan_rollups es SECURITY DEFINER');
select ok((select prosecdef from pg_proc where oid = 'private.run_scan_rollups()'::regprocedure),
  'run_scan_rollups es SECURITY DEFINER');
select ok(not (select prosecdef from pg_proc where oid = 'public.link_stats(uuid, date, date)'::regprocedure),
  'link_stats es SECURITY INVOKER');
select ok(not (select prosecdef from pg_proc where oid = 'public.org_stats(uuid, date, date)'::regprocedure),
  'org_stats es SECURITY INVOKER');
select is(
  (select count(*)::int from pg_proc
   where oid in ('private.refresh_scan_rollups(date, date)'::regprocedure,
                 'private.run_scan_rollups()'::regprocedure,
                 'private.scan_rollups_closed_through()'::regprocedure,
                 'public.link_stats(uuid, date, date)'::regprocedure,
                 'public.org_stats(uuid, date, date)'::regprocedure)
     and proconfig @> array['search_path=""']),
  5, 'todas las funciones fijan search_path vacío');

select table_privs_are('public', 'scan_daily_rollups', 'authenticated', array['SELECT'],
  'authenticated solo tiene SELECT');
select table_privs_are('public', 'scan_daily_rollups', 'anon', array[]::text[],
  'anon no tiene privilegios');
select ok(not has_function_privilege('authenticated', 'private.refresh_scan_rollups(date, date)', 'execute'),
  'authenticated no ejecuta refresh_scan_rollups');
select ok(not has_function_privilege('authenticated', 'private.run_scan_rollups()', 'execute'),
  'authenticated no ejecuta run_scan_rollups');
select ok(not has_function_privilege('anon', 'public.link_stats(uuid, date, date)', 'execute'),
  'anon no ejecuta link_stats');
select ok(not has_function_privilege('anon', 'public.org_stats(uuid, date, date)', 'execute'),
  'anon no ejecuta org_stats');
select ok(has_function_privilege('service_role', 'private.refresh_scan_rollups(date, date)', 'execute'),
  'service_role ejecuta refresh_scan_rollups');

select ok(
  not exists (select 1 from pg_extension where extname = 'pg_cron')
  or (select count(*) = 1 from cron.job
      where jobname = 'dqr_scan_rollups'
        and schedule = '*/15 * * * *'
        and command = 'select private.run_scan_rollups()'),
  'job pg_cron dqr_scan_rollups cada 15 min (si pg_cron está instalado)');

-- -----------------------------------------------------------------------------
-- refresh: valores, bots, únicos, idempotencia
-- -----------------------------------------------------------------------------
select is(private.refresh_scan_rollups(pg_temp.d(3), pg_temp.d(0)), 4,
  'el primer refresh crea 4 filas');

select results_eq(
  $$ select link_id::text, day, scans, unique_visitors, qr, nfc, direct
     from public.scan_daily_rollups order by link_id, day $$,
  $$ values
     ('a0000000-0000-0000-0000-000000000001', pg_temp.d(2), 5, 3, 3, 1, 1),
     ('a0000000-0000-0000-0000-000000000001', pg_temp.d(0), 2, 2, 2, 0, 0),
     ('a0000000-0000-0000-0000-000000000002', pg_temp.d(2), 1, 1, 0, 0, 1),
     ('b0000000-0000-0000-0000-000000000001', pg_temp.d(2), 2, 2, 2, 0, 0) $$,
  'rollups correctos: bots fuera, únicos = ip_hash distintos (NULL no cuenta), canales');

select ok(
  not exists (select 1 from public.scan_daily_rollups where day = pg_temp.d(3)),
  'un día con solo bots no genera fila');
select is(
  (select org_id::text from public.scan_daily_rollups
   where link_id = 'b0000000-0000-0000-0000-000000000001'),
  '0000000b-0000-0000-0000-000000000000', 'org_id copiado del evento');
select is(
  (select scans from public.scan_daily_rollups
   where link_id = 'a0000000-0000-0000-0000-000000000001' and day = pg_temp.d(0)),
  2, 'el evento de las 00:00 UTC cuenta en el día UTC (no en el local)');

create temp table snap as
  select link_id, day, scans, unique_visitors, qr, nfc, direct, updated_at
  from public.scan_daily_rollups;

select is(private.refresh_scan_rollups(pg_temp.d(3), pg_temp.d(0)), 0,
  'idempotente: el segundo refresh no toca filas');
select results_eq(
  $$ select link_id, day, scans, unique_visitors, qr, nfc, direct, updated_at
     from public.scan_daily_rollups order by link_id, day $$,
  $$ select * from snap order by link_id, day $$,
  'idempotente: mismas filas y mismo updated_at');
select is(private.refresh_scan_rollups(pg_temp.d(30), pg_temp.d(0)), 0,
  'idempotente también con un rango más amplio');

-- Un escaneo nuevo en un día ya calculado se refleja en el siguiente refresh.
insert into public.scan_events (link_id, org_id, channel, occurred_at, ip_hash)
values ('a0000000-0000-0000-0000-000000000001', '0000000a-0000-0000-0000-000000000000',
        'qr', pg_temp.ts(2, '16:00'), pg_temp.h('4'));
select is(private.refresh_scan_rollups(pg_temp.d(2), pg_temp.d(2)), 1,
  'el refresh actualiza solo la fila que cambia');
select row_eq(
  $$ select scans, unique_visitors, qr, nfc, direct from public.scan_daily_rollups
     where link_id = 'a0000000-0000-0000-0000-000000000001' and day = pg_temp.d(2) $$,
  row(6, 4, 4, 1, 1),
  'A1 en T-2 tras el nuevo escaneo: 6 escaneos, 4 únicos');

-- Las filas del rango que ya no tienen escaneos se borran.
insert into public.scan_events (link_id, org_id, channel, occurred_at, ip_hash)
values ('a0000000-0000-0000-0000-000000000002', '0000000a-0000-0000-0000-000000000000',
        'direct', pg_temp.ts(3, '09:00'), pg_temp.h('5'));
select is(private.refresh_scan_rollups(pg_temp.d(3), pg_temp.d(3)), 1,
  'nueva fila para A2 en T-3');
delete from public.scan_events
where link_id = 'a0000000-0000-0000-0000-000000000002' and occurred_at = pg_temp.ts(3, '09:00');
select is(private.refresh_scan_rollups(pg_temp.d(3), pg_temp.d(3)), 1,
  'el refresh borra la fila que se quedó sin escaneos');
select ok(
  not exists (select 1 from public.scan_daily_rollups
              where link_id = 'a0000000-0000-0000-0000-000000000002' and day = pg_temp.d(3)),
  'A2 en T-3 ya no está');
select is(
  (select count(*)::int from public.scan_daily_rollups where day = pg_temp.d(2)),
  3, 'un refresh de otro día no toca T-2');

select throws_ok(
  $$ select private.refresh_scan_rollups(pg_temp.d(0), pg_temp.d(1)) $$,
  '22023', null, 'refresh rechaza p_from > p_to');
select throws_ok(
  $$ select private.refresh_scan_rollups(null, pg_temp.d(0)) $$,
  '22023', null, 'refresh rechaza nulos');

-- -----------------------------------------------------------------------------
-- Marca de agua y job
-- -----------------------------------------------------------------------------
select is(private.scan_rollups_closed_through(), pg_temp.d(1),
  'tras refrescar hasta hoy la marca queda en ayer');

select pg_temp.set_closed(pg_temp.d(5));
select private.refresh_scan_rollups(pg_temp.d(1), pg_temp.d(0));
select is(private.scan_rollups_closed_through(), pg_temp.d(5),
  'la marca no avanza si el rango deja un hueco');
select private.refresh_scan_rollups(pg_temp.d(4), pg_temp.d(0));
select is(private.scan_rollups_closed_through(), pg_temp.d(1),
  'la marca avanza con un rango contiguo');
select private.refresh_scan_rollups(pg_temp.d(3), pg_temp.d(3));
select is(private.scan_rollups_closed_through(), pg_temp.d(1),
  'la marca nunca retrocede');

select pg_temp.set_closed(pg_temp.d(40));
select private.run_scan_rollups();
select is(private.scan_rollups_closed_through(), pg_temp.d(8),
  'el job se pone al día como máximo 32 días por pasada');
select private.run_scan_rollups();
select is(private.scan_rollups_closed_through(), pg_temp.d(1),
  'la siguiente pasada llega hasta ayer');
select lives_ok($$ select private.run_scan_rollups() $$,
  'el job normal (ayer + hoy) funciona');

-- -----------------------------------------------------------------------------
-- RLS y escritura
-- -----------------------------------------------------------------------------
select pg_temp.login('00000000-0000-0000-0000-0000000000a2');
select is((select count(*)::int from public.scan_daily_rollups), 3,
  'viewer de A ve las 3 filas de A');
select is((select count(*)::int from public.scan_daily_rollups
           where org_id <> '0000000a-0000-0000-0000-000000000000'), 0,
  'viewer de A no ve filas de B');
select pg_temp.logout();

select pg_temp.login('00000000-0000-0000-0000-0000000000b1');
select is((select count(*)::int from public.scan_daily_rollups), 1,
  'owner de B ve solo su fila');
select pg_temp.logout();

select pg_temp.login('00000000-0000-0000-0000-0000000000cc');
select is((select count(*)::int from public.scan_daily_rollups), 0,
  'usuario sin org no ve nada');
select pg_temp.logout();

select pg_temp.login('00000000-0000-0000-0000-0000000000ff');
select is((select count(*)::int from public.scan_daily_rollups), 4,
  'platform admin ve todo');
select pg_temp.logout();

select pg_temp.login('00000000-0000-0000-0000-0000000000a1');
select throws_ok(
  $$ insert into public.scan_daily_rollups (link_id, org_id, day, scans, unique_visitors, qr, nfc, direct)
     values ('a0000000-0000-0000-0000-000000000001', '0000000a-0000-0000-0000-000000000000',
             pg_temp.d(10), 1, 1, 1, 0, 0) $$,
  '42501', null, 'owner no puede insertar rollups');
select throws_ok(
  $$ update public.scan_daily_rollups set scans = scans $$,
  '42501', null, 'owner no puede actualizar rollups');
select throws_ok(
  $$ delete from public.scan_daily_rollups $$,
  '42501', null, 'owner no puede borrar rollups');
select throws_ok(
  $$ select private.refresh_scan_rollups(pg_temp.d(1), pg_temp.d(0)) $$,
  '42501', null, 'owner no puede ejecutar refresh_scan_rollups');
select throws_ok(
  $$ select private.run_scan_rollups() $$,
  '42501', null, 'owner no puede ejecutar run_scan_rollups');
select throws_ok(
  $$ update private.scan_rollup_state set closed_through = null $$,
  '42501', null, 'owner no puede mover la marca de agua');
select pg_temp.logout();

select pg_temp.as_role('anon');
select throws_ok(
  $$ select count(*) from public.scan_daily_rollups $$,
  '42501', null, 'anon no lee rollups');
select throws_ok(
  $$ select * from public.link_stats('a0000000-0000-0000-0000-000000000001', pg_temp.d(3), pg_temp.d(0)) $$,
  '42501', null, 'anon no ejecuta link_stats');
select pg_temp.logout();

-- -----------------------------------------------------------------------------
-- link_stats / org_stats
-- -----------------------------------------------------------------------------
-- Escaneo de hoy que aún no está en los rollups: debe salir por el conteo en vivo.
insert into public.scan_events (link_id, org_id, channel, occurred_at, ip_hash)
values ('a0000000-0000-0000-0000-000000000001', '0000000a-0000-0000-0000-000000000000',
        'nfc', pg_temp.ts(0, '00:03'), pg_temp.h('3'));

select pg_temp.login('00000000-0000-0000-0000-0000000000a2');
select results_eq(
  $$ select * from public.link_stats('a0000000-0000-0000-0000-000000000001', pg_temp.d(3), pg_temp.d(0)) $$,
  $$ values (pg_temp.d(2), 6, 4, 4, 1, 1), (pg_temp.d(0), 3, 3, 2, 1, 0) $$,
  'link_stats (viewer): días cerrados de rollups + hoy en vivo, sin bots');
select results_eq(
  $$ select * from public.org_stats('0000000a-0000-0000-0000-000000000000', pg_temp.d(3), pg_temp.d(0)) $$,
  $$ values (pg_temp.d(2), 7, 5, 4, 1, 2), (pg_temp.d(0), 3, 3, 2, 1, 0) $$,
  'org_stats (viewer): suma de enlaces por día; únicos = suma de únicos por enlace');
select results_eq(
  $$ select * from public.link_stats('a0000000-0000-0000-0000-000000000001', pg_temp.d(1), pg_temp.d(1)) $$,
  $$ select * from (values (null::date, 0, 0, 0, 0, 0)) v where false $$,
  'link_stats de un día sin escaneos → vacío');
select is(
  (select count(*)::int from public.link_stats('a0000000-0000-0000-0000-000000000001', pg_temp.d(2), pg_temp.d(2))),
  1, 'el rango se respeta (solo T-2)');
select throws_ok(
  $$ select * from public.link_stats('a0000000-0000-0000-0000-000000000001', pg_temp.d(0), pg_temp.d(1)) $$,
  '22023', null, 'link_stats rechaza p_from > p_to');
select throws_ok(
  $$ select * from public.org_stats('0000000a-0000-0000-0000-000000000000', pg_temp.d(400), pg_temp.d(0)) $$,
  '22023', null, 'org_stats rechaza más de 366 días');
select lives_ok(
  $$ select * from public.link_stats('a0000000-0000-0000-0000-000000000001', pg_temp.d(365), pg_temp.d(0)) $$,
  'link_stats admite 366 días');
select is(
  (select count(*)::int from public.link_stats('b0000000-0000-0000-0000-000000000001', pg_temp.d(3), pg_temp.d(0))),
  0, 'link_stats de un enlace de otra org → vacío');
select pg_temp.logout();

select pg_temp.login('00000000-0000-0000-0000-0000000000b1');
select is(
  (select count(*)::int from public.link_stats('a0000000-0000-0000-0000-000000000001', pg_temp.d(3), pg_temp.d(0))),
  0, 'link_stats con una org ajena → vacío (owner de B sobre A1)');
select is(
  (select count(*)::int from public.org_stats('0000000a-0000-0000-0000-000000000000', pg_temp.d(3), pg_temp.d(0))),
  0, 'org_stats de una org ajena → vacío');
select results_eq(
  $$ select * from public.org_stats('0000000b-0000-0000-0000-000000000000', pg_temp.d(3), pg_temp.d(0)) $$,
  $$ values (pg_temp.d(2), 2, 2, 2, 0, 0) $$,
  'org_stats de su propia org');
select pg_temp.logout();

select pg_temp.login('00000000-0000-0000-0000-0000000000cc');
select is(
  (select count(*)::int from public.org_stats('0000000a-0000-0000-0000-000000000000', pg_temp.d(3), pg_temp.d(0))),
  0, 'usuario sin org → vacío');
select pg_temp.logout();

-- sec-T041 H1: un extraño no hace leer scan_events ni scan_daily_rollups.
create temp table io_before as
  select relname, coalesce(seq_scan, 0) + coalesce(idx_scan, 0) as n
  from pg_stat_xact_user_tables
  where schemaname = 'public' and relname in ('scan_events', 'scan_daily_rollups');
select pg_temp.login('00000000-0000-0000-0000-0000000000cc');
select count(*) from public.org_stats('0000000a-0000-0000-0000-000000000000', pg_temp.d(365), pg_temp.d(0));
select count(*) from public.link_stats('a0000000-0000-0000-0000-000000000001', pg_temp.d(365), pg_temp.d(0));
select pg_temp.logout();
select pg_temp.login('00000000-0000-0000-0000-0000000000b1');
select count(*) from public.org_stats('0000000a-0000-0000-0000-000000000000', pg_temp.d(365), pg_temp.d(0));
select count(*) from public.link_stats('a0000000-0000-0000-0000-000000000001', pg_temp.d(365), pg_temp.d(0));
select pg_temp.logout();
select is(
  (select count(*)::int
   from pg_stat_xact_user_tables s
   join io_before b using (relname)
   where s.schemaname = 'public'
     and coalesce(s.seq_scan, 0) + coalesce(s.idx_scan, 0) <> b.n),
  0, 'H1: org_stats/link_stats de un extraño no tocan scan_events ni scan_daily_rollups');
select pg_temp.login('00000000-0000-0000-0000-0000000000a2');
select count(*) from public.link_stats('a0000000-0000-0000-0000-000000000001', pg_temp.d(3), pg_temp.d(0));
select pg_temp.logout();
select ok(
  (select sum(coalesce(s.seq_scan, 0) + coalesce(s.idx_scan, 0)) from pg_stat_xact_user_tables s
   where s.schemaname = 'public' and s.relname in ('scan_events', 'scan_daily_rollups'))
  > (select sum(n) from io_before),
  'H1: el contador sí sube cuando llama un miembro (la sonda funciona)');

-- sec-T041 H2: políticas por conjunto con private.my_org_ids().
select ok(
  (select prosecdef from pg_proc where oid = 'private.my_org_ids()'::regprocedure)
  and (select proconfig @> array['search_path=""'] from pg_proc where oid = 'private.my_org_ids()'::regprocedure),
  'H2: my_org_ids es SECURITY DEFINER con search_path vacío');
select ok(not has_function_privilege('anon', 'private.my_org_ids()', 'execute'),
  'H2: anon no ejecuta my_org_ids');
select ok(has_function_privilege('authenticated', 'private.my_org_ids()', 'execute'),
  'H2: authenticated ejecuta my_org_ids');
select ok(
  (select qual like '%my_org_ids()%' and qual not like '%is_org_member%'
   from pg_policies where schemaname = 'public' and policyname = 'scan_daily_rollups_select'),
  'H2: scan_daily_rollups_select usa my_org_ids()');
select ok(
  (select qual like '%my_org_ids()%' and qual not like '%is_org_member%'
   from pg_policies where schemaname = 'public' and policyname = 'scan_events_select'),
  'H2: scan_events_select usa my_org_ids()');
select pg_temp.login('00000000-0000-0000-0000-0000000000a2');
select results_eq(
  $$ select private.my_org_ids()::text $$,
  $$ values ('0000000a-0000-0000-0000-000000000000') $$,
  'H2: my_org_ids devuelve solo las orgs del usuario');
select is((select count(*)::int from public.scan_events
           where org_id <> '0000000a-0000-0000-0000-000000000000'), 0,
  'H2: con la nueva política, el viewer de A no ve eventos de B');
select is((select count(*)::int from public.scan_events), 14,
  'H2: el viewer de A ve todos los eventos de A (bots incluidos)');
select pg_temp.logout();
select pg_temp.login('00000000-0000-0000-0000-0000000000cc');
select is((select count(*)::int from public.scan_events), 0,
  'H2: usuario sin org no ve eventos');
select pg_temp.logout();
select pg_temp.login('00000000-0000-0000-0000-0000000000ff');
select is((select count(*)::int from public.scan_events), 16,
  'H2: platform admin ve todos los eventos');
select pg_temp.logout();

select pg_temp.login('00000000-0000-0000-0000-0000000000ff');
select is(
  (select count(*)::int from public.org_stats('0000000a-0000-0000-0000-000000000000', pg_temp.d(3), pg_temp.d(0))),
  2, 'platform admin ve las métricas de A');
select pg_temp.logout();

-- Sin marca de agua todo sale en vivo y el resultado es el mismo.
select pg_temp.set_closed(null);
select pg_temp.login('00000000-0000-0000-0000-0000000000a2');
select results_eq(
  $$ select * from public.link_stats('a0000000-0000-0000-0000-000000000001', pg_temp.d(3), pg_temp.d(0)) $$,
  $$ values (pg_temp.d(2), 6, 4, 4, 1, 1), (pg_temp.d(0), 3, 3, 2, 1, 0) $$,
  'link_stats en vivo (sin marca) = rollups + vivo');
select results_eq(
  $$ select * from public.org_stats('0000000a-0000-0000-0000-000000000000', pg_temp.d(3), pg_temp.d(0)) $$,
  $$ values (pg_temp.d(2), 7, 5, 4, 1, 2), (pg_temp.d(0), 3, 3, 2, 1, 0) $$,
  'org_stats en vivo (sin marca) = rollups + vivo');
select pg_temp.logout();

-- Los días cerrados se leen de los rollups (no de scan_events).
select pg_temp.set_closed(pg_temp.d(1));
delete from public.scan_events
where link_id = 'a0000000-0000-0000-0000-000000000001' and occurred_at = pg_temp.ts(2, '16:00');
select pg_temp.login('00000000-0000-0000-0000-0000000000a2');
select is(
  (select scans from public.link_stats('a0000000-0000-0000-0000-000000000001', pg_temp.d(2), pg_temp.d(2))),
  6, 'día cerrado: sale del rollup aunque scan_events haya cambiado');
select pg_temp.logout();
select pg_temp.set_closed(pg_temp.d(3));
select pg_temp.login('00000000-0000-0000-0000-0000000000a2');
select is(
  (select scans from public.link_stats('a0000000-0000-0000-0000-000000000001', pg_temp.d(2), pg_temp.d(2))),
  5, 'día abierto (después de la marca): sale en vivo');
select pg_temp.logout();

-- -----------------------------------------------------------------------------
-- Cascada
-- -----------------------------------------------------------------------------
delete from public.dynamic_links where id = 'a0000000-0000-0000-0000-000000000002';
select is(
  (select count(*)::int from public.scan_daily_rollups
   where link_id = 'a0000000-0000-0000-0000-000000000002'),
  0, 'borrar el enlace borra sus rollups');

select * from finish();
rollback;
