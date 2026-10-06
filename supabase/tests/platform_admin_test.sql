-- DQR-T051 / DQR-T054 · Tests de las RPC de la consola de plataforma (pgTAP).
-- Ejecutar: supabase test db (o psql -f). Todo dentro de BEGIN … ROLLBACK.
begin;

create extension if not exists pgtap with schema extensions;

select plan(123);

-- -----------------------------------------------------------------------------
-- Fixtures (como postgres)
-- -----------------------------------------------------------------------------
-- Org A: o1 owner · ed editor. Org B ('Beta 100% real'): ob owner.
-- pa platform admin (sin membresías). u5 sin org.
insert into auth.users (id, email, aud, role) values
  ('00000000-0000-0000-0000-0000000000a1', 'o1@test.local', 'authenticated', 'authenticated'),
  ('00000000-0000-0000-0000-0000000000ed', 'ed@test.local', 'authenticated', 'authenticated'),
  ('00000000-0000-0000-0000-0000000000b1', 'ob@test.local', 'authenticated', 'authenticated'),
  ('00000000-0000-0000-0000-0000000000ff', 'pa@test.local', 'authenticated', 'authenticated'),
  ('00000000-0000-0000-0000-0000000000c5', 'u5@test.local', 'authenticated', 'authenticated');

insert into public.platform_admins (user_id) values ('00000000-0000-0000-0000-0000000000ff');

insert into public.organizations (id, name, slug) values
  ('0000000a-0000-0000-0000-000000000000', 'Org A', 'org-a-t051'),
  ('0000000b-0000-0000-0000-000000000000', 'Beta 100% real', 'org-b-t051');

insert into public.memberships (org_id, user_id, role) values
  ('0000000a-0000-0000-0000-000000000000', '00000000-0000-0000-0000-0000000000a1', 'owner'),
  ('0000000a-0000-0000-0000-000000000000', '00000000-0000-0000-0000-0000000000ed', 'editor'),
  ('0000000b-0000-0000-0000-000000000000', '00000000-0000-0000-0000-0000000000b1', 'owner');

-- 2 enlaces en A (uno con slug conocido; service_role/postgres pueden fijarlo).
insert into public.dynamic_links (id, org_id, slug, name, destination_url) values
  ('a1000000-0000-0000-0000-000000000001', '0000000a-0000-0000-0000-000000000000',
   'AbC1234', 'Menú', 'https://menu.example.com/'),
  ('a1000000-0000-0000-0000-000000000002', '0000000a-0000-0000-0000-000000000000',
   'XyZ9876', 'Promo', 'https://promo.example.com/');

-- Escaneos en A: 3 humanos recientes, 1 bot reciente, 1 humano de hace 40 días.
insert into public.scan_events (link_id, org_id, channel, occurred_at, is_bot) values
  ('a1000000-0000-0000-0000-000000000001', '0000000a-0000-0000-0000-000000000000', 'qr',     now() - interval '1 day',   false),
  ('a1000000-0000-0000-0000-000000000001', '0000000a-0000-0000-0000-000000000000', 'nfc',    now() - interval '10 days', false),
  ('a1000000-0000-0000-0000-000000000002', '0000000a-0000-0000-0000-000000000000', 'direct', now(),                      false),
  ('a1000000-0000-0000-0000-000000000002', '0000000a-0000-0000-0000-000000000000', 'qr',     now(),                      true),
  ('a1000000-0000-0000-0000-000000000001', '0000000a-0000-0000-0000-000000000000', 'qr',     now() - interval '40 days', false);

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

-- Las funciones pg_temp no son visibles para authenticated: se consulta como postgres.
create function pg_temp.audit_rows(p_entity text, p_entity_id text)
returns table (action text, actor uuid, org_id uuid, diff jsonb)
language sql as $$
  select a.action, a.actor, a.org_id, a.diff from public.audit_log a
  where a.entity = p_entity and a.entity_id = p_entity_id
  order by a.id
$$;

-- -----------------------------------------------------------------------------
-- Catálogo: SECURITY DEFINER, search_path vacío, EXECUTE solo authenticated
-- -----------------------------------------------------------------------------
create temp table t051_funcs (sig regprocedure);
insert into t051_funcs values
  ('public.my_effective_role(uuid)'),
  ('public.admin_list_orgs(text, int, int)'),
  ('public.admin_update_org(uuid, text, public.org_status, jsonb)'),
  ('public.admin_list_blocked_domains()'),
  ('public.admin_block_domain(text)'),
  ('public.admin_unblock_domain(text)'),
  ('public.admin_set_link_status(uuid, public.link_status)'),
  ('public.admin_find_link(text)'),
  ('public.am_i_platform_admin()'),
  ('public.admin_suspend_link(uuid, boolean, text)');

select is(
  (select count(*) from t051_funcs f join pg_proc p on p.oid = f.sig
    where p.prosecdef and p.proconfig = array['search_path=""']),
  10::bigint, 'las 10 RPC son SECURITY DEFINER con search_path vacío');
select is(
  (select count(*) from t051_funcs f where has_function_privilege('authenticated', f.sig, 'execute')),
  10::bigint, 'authenticated puede ejecutar las 10 RPC');
select is(
  (select count(*) from t051_funcs f where has_function_privilege('anon', f.sig, 'execute')),
  0::bigint, 'anon no puede ejecutar ninguna');
select is(
  (select count(*) from t051_funcs f where has_function_privilege('service_role', f.sig, 'execute')),
  0::bigint, 'service_role no puede ejecutar ninguna');
select ok(
  not has_function_privilege('authenticated', 'private.assert_platform_admin()', 'execute'),
  'authenticated no ejecuta private.assert_platform_admin directamente');

-- -----------------------------------------------------------------------------
-- Usuario normal (owner de A): 42501 en todas las admin_*
-- -----------------------------------------------------------------------------
select pg_temp.login('00000000-0000-0000-0000-0000000000a1');

select throws_ok($$select * from public.admin_list_orgs()$$,
  '42501', null, 'owner: admin_list_orgs → 42501');
select throws_ok(
  $$select public.admin_update_org('0000000a-0000-0000-0000-000000000000', p_plan => 'pro')$$,
  '42501', null, 'owner: admin_update_org (su propia org) → 42501');
select throws_ok($$select * from public.admin_list_blocked_domains()$$,
  '42501', null, 'owner: admin_list_blocked_domains → 42501');
select throws_ok($$select public.admin_block_domain('evil.example.com')$$,
  '42501', null, 'owner: admin_block_domain → 42501');
select throws_ok($$select public.admin_unblock_domain('evil.example.com')$$,
  '42501', null, 'owner: admin_unblock_domain → 42501');
select throws_ok(
  $$select public.admin_set_link_status('a1000000-0000-0000-0000-000000000001', 'paused')$$,
  '42501', null, 'owner: admin_set_link_status (su propio enlace) → 42501');
select throws_ok($$select * from public.admin_find_link('AbC1234')$$,
  '42501', null, 'owner: admin_find_link → 42501');
select throws_ok(
  $$select public.admin_suspend_link('a1000000-0000-0000-0000-000000000001', true)$$,
  '42501', null, 'owner: admin_suspend_link (su propio enlace) → 42501');
select is(public.am_i_platform_admin(), false, 'am_i_platform_admin: owner → false');

select is(public.my_effective_role('0000000a-0000-0000-0000-000000000000'), 'owner'::public.org_role,
  'my_effective_role: owner de A → owner');
select is(public.my_effective_role('0000000b-0000-0000-0000-000000000000'), null::public.org_role,
  'my_effective_role: owner de A en B → NULL');
select pg_temp.logout();

-- Sin org y editor
select pg_temp.login('00000000-0000-0000-0000-0000000000c5');
select throws_ok($$select * from public.admin_list_orgs()$$,
  '42501', null, 'sin org: admin_list_orgs → 42501');
select throws_ok($$select public.admin_block_domain('evil.example.com')$$,
  '42501', null, 'sin org: admin_block_domain → 42501');
select is(public.my_effective_role('0000000a-0000-0000-0000-000000000000'), null::public.org_role,
  'my_effective_role: sin membresía → NULL');
select pg_temp.logout();

select pg_temp.login('00000000-0000-0000-0000-0000000000ed');
select throws_ok(
  $$select public.admin_set_link_status('a1000000-0000-0000-0000-000000000001', 'archived')$$,
  '42501', null, 'editor: admin_set_link_status → 42501');
select is(public.my_effective_role('0000000a-0000-0000-0000-000000000000'), 'editor'::public.org_role,
  'my_effective_role: editor de A → editor');
select pg_temp.logout();

-- anon no puede llamar a ninguna (sin EXECUTE)
set local role anon;
select throws_ok($$select public.my_effective_role('0000000a-0000-0000-0000-000000000000')$$,
  '42501', null, 'anon: my_effective_role → 42501 (sin EXECUTE)');
select throws_ok($$select * from public.admin_list_orgs()$$,
  '42501', null, 'anon: admin_list_orgs → 42501 (sin EXECUTE)');
reset role;

-- Nada cambió por los intentos fallidos
select is((select count(*) from public.audit_log
            where actor is not null and org_id in ('0000000a-0000-0000-0000-000000000000',
                             '00000000-0000-0000-0000-000000000000')),
  0::bigint, 'los intentos rechazados no dejan auditoría');

-- -----------------------------------------------------------------------------
-- Platform admin: my_effective_role
-- -----------------------------------------------------------------------------
select pg_temp.login('00000000-0000-0000-0000-0000000000ff');
select is(public.my_effective_role('0000000a-0000-0000-0000-000000000000'), 'owner'::public.org_role,
  'my_effective_role: platform admin sin membresía → owner');
select is(public.my_effective_role('0000000b-0000-0000-0000-000000000000'), 'owner'::public.org_role,
  'my_effective_role: platform admin en B → owner');
select is(public.my_effective_role('0000dead-0000-0000-0000-000000000000'), null::public.org_role,
  'my_effective_role: platform admin en org inexistente → NULL');
select is(public.am_i_platform_admin(), true, 'am_i_platform_admin: platform admin → true');

-- -----------------------------------------------------------------------------
-- Platform admin: admin_list_orgs
-- -----------------------------------------------------------------------------
select is(
  (select row(o.name, o.slug, o.plan, o.status, o.members, o.links, o.scans_30d)::text
     from public.admin_list_orgs('org-a-t051') o),
  row('Org A', 'org-a-t051', 'free', 'active'::public.org_status, 2::bigint, 2::bigint, 3::bigint)::text,
  'admin_list_orgs: A con 2 miembros, 2 enlaces y 3 escaneos humanos en 30 días');
select is(
  (select row(o.members, o.links, o.scans_30d)::text
     from public.admin_list_orgs('org-b-t051') o),
  row(1::bigint, 0::bigint, 0::bigint)::text,
  'admin_list_orgs: B con 1 miembro y sin enlaces ni escaneos');
select is((select count(*) from public.admin_list_orgs('ORG-A-T051')), 1::bigint,
  'admin_list_orgs: búsqueda sin distinguir mayúsculas');
select is((select count(*) from public.admin_list_orgs('Org A')), 1::bigint,
  'admin_list_orgs: busca también por name');
select is(array(select o.id from public.admin_list_orgs('100%') o),
  array['0000000b-0000-0000-0000-000000000000'::uuid],
  'admin_list_orgs: % en q es literal');
select is((select count(*) from public.admin_list_orgs('1_0')), 0::bigint,
  'admin_list_orgs: _ en q es literal (no comodín)');
select is((select count(*) from public.admin_list_orgs('t051')), 2::bigint,
  'admin_list_orgs: q coincide con ambas orgs');
select is(array(select o.id from public.admin_list_orgs('t051', 1, 0) o),
  array['0000000a-0000-0000-0000-000000000000'::uuid],
  'admin_list_orgs: limit 1 (orden created_at desc, id)');
select is(array(select o.id from public.admin_list_orgs('t051', 1, 1) o),
  array['0000000b-0000-0000-0000-000000000000'::uuid],
  'admin_list_orgs: offset 1');
select is((select count(*) from public.admin_list_orgs('t051', 0, -5)), 1::bigint,
  'admin_list_orgs: limit < 1 se acota a 1 y offset negativo a 0');
select is((select count(*) from public.admin_list_orgs('   ')), (select count(*) from public.organizations),
  'admin_list_orgs: q en blanco = sin filtro');

-- -----------------------------------------------------------------------------
-- Platform admin: admin_update_org (auditado)
-- -----------------------------------------------------------------------------
select is(
  (select row(o.plan, o.status, o.limits)::text
     from public.admin_update_org('0000000a-0000-0000-0000-000000000000',
            'pro', 'suspended', '{"max_links": 5}') o),
  row('pro', 'suspended'::public.org_status, '{"max_links": 5}'::jsonb)::text,
  'admin_update_org: cambia plan, status y limits');
select pg_temp.logout();

select is(
  array(select row(a.action, a.actor, a.diff)::text
          from pg_temp.audit_rows('org', '0000000a-0000-0000-0000-000000000000') a),
  array[
    row('org.status_changed', '00000000-0000-0000-0000-0000000000ff'::uuid,
        '{"status": {"old": "active", "new": "suspended"}, "plan": {"old": "free", "new": "pro"}}'::jsonb)::text,
    row('org.limits_changed', '00000000-0000-0000-0000-0000000000ff'::uuid,
        '{"limits": {"old": {}, "new": {"max_links": 5}}}'::jsonb)::text],
  'auditoría: org.status_changed (plan+status) y org.limits_changed con actor = platform admin');

select pg_temp.login('00000000-0000-0000-0000-0000000000ff');
select is(
  (select row(o.plan, o.status, o.limits)::text
     from public.admin_update_org('0000000a-0000-0000-0000-000000000000',
            p_status => 'active') o),
  row('pro', 'active'::public.org_status, '{"max_links": 5}'::jsonb)::text,
  'admin_update_org: parámetros NULL conservan el valor (reactivar)');
select is(
  (select o.limits from public.admin_update_org('0000000a-0000-0000-0000-000000000000',
            p_limits => '{}') o),
  '{}'::jsonb, 'admin_update_org: limits {} quita los overrides');
select throws_ok(
  $$select public.admin_update_org('0000000a-0000-0000-0000-000000000000', p_plan => 'gold')$$,
  '23503', null, 'admin_update_org: plan inexistente → 23503');
select throws_ok(
  $$select public.admin_update_org('0000000a-0000-0000-0000-000000000000', p_limits => '{"max_foo": 1}')$$,
  '23514', null, 'admin_update_org: clave de límite desconocida → 23514');
select throws_ok(
  $$select public.admin_update_org('0000000a-0000-0000-0000-000000000000', p_limits => '{"max_links": -1}')$$,
  '23514', null, 'admin_update_org: límite negativo → 23514');
select throws_ok(
  $$select public.admin_update_org('0000000a-0000-0000-0000-000000000000', p_limits => '[]')$$,
  '23514', null, 'admin_update_org: limits que no es objeto → 23514');
select throws_ok(
  $$select public.admin_update_org('0000dead-0000-0000-0000-000000000000', p_plan => 'pro')$$,
  'P0002', null, 'admin_update_org: org inexistente → P0002');
select pg_temp.logout();

select is(
  array(select a.action from pg_temp.audit_rows('org', '0000000a-0000-0000-0000-000000000000') a),
  array['org.status_changed', 'org.limits_changed', 'org.status_changed', 'org.limits_changed'],
  'auditoría: reactivar y quitar overrides quedan registrados; los fallidos no');
select is(
  (select row(o.plan, o.status, o.limits)::text from public.organizations o
    where o.id = '0000000a-0000-0000-0000-000000000000'),
  row('pro', 'active'::public.org_status, '{}'::jsonb)::text,
  'los cambios fallidos no modificaron la org');

-- -----------------------------------------------------------------------------
-- Platform admin: blocklist (normalización, validación, auditoría, efecto)
-- -----------------------------------------------------------------------------
select pg_temp.login('00000000-0000-0000-0000-0000000000ff');
select lives_ok($$select public.admin_block_domain('  .EVIL.Example.COM.. ')$$,
  'admin_block_domain: acepta dominio con mayúsculas, espacios y puntos extremos');
select is(
  (select count(*) from public.admin_list_blocked_domains() d where d.domain = 'evil.example.com'),
  1::bigint, 'admin_block_domain: guarda el dominio normalizado');
select lives_ok($$select public.admin_block_domain('evil.example.com')$$,
  'admin_block_domain: bloquear de nuevo es idempotente');
select lives_ok($$select public.admin_block_domain('Ejemplo-Malo.TEST')$$,
  'admin_block_domain: segundo dominio');
select is(
  array(select d.domain from public.admin_list_blocked_domains() d
         where d.domain in ('evil.example.com', 'ejemplo-malo.test')),
  array['ejemplo-malo.test', 'evil.example.com'],
  'admin_list_blocked_domains: lista ordenada por dominio');

select throws_ok($$select public.admin_block_domain('bad domain.com')$$,
  '23514', null, 'admin_block_domain: espacio interno → 23514');
select throws_ok($$select public.admin_block_domain('https://evil.example.com')$$,
  '23514', null, 'admin_block_domain: URL en vez de dominio → 23514');
select throws_ok($$select public.admin_block_domain('evil..example.com')$$,
  '23514', null, 'admin_block_domain: label vacío → 23514');
select throws_ok($$select public.admin_block_domain('-evil.com')$$,
  '23514', null, 'admin_block_domain: label que empieza por guion → 23514');
select throws_ok($$select public.admin_block_domain('ejémplo.com')$$,
  '23514', null, 'admin_block_domain: IDN sin punycode → 23514');
select throws_ok($$select public.admin_block_domain('...')$$,
  '23514', null, 'admin_block_domain: solo puntos → 23514');
select throws_ok($$select public.admin_block_domain('')$$,
  '23514', null, 'admin_block_domain: vacío → 23514');
select throws_ok($$select public.admin_block_domain(null)$$,
  '23514', null, 'admin_block_domain: NULL → 23514');
select throws_ok($$select public.admin_block_domain('com')$$,
  '23514', null, 'admin_block_domain: TLD solo → 23514 (H3)');
select throws_ok($$select public.admin_block_domain('.COM.')$$,
  '23514', null, 'admin_block_domain: TLD con puntos extremos → 23514 (H3)');
select throws_ok($$select public.admin_block_domain('localhost')$$,
  '23514', null, 'admin_block_domain: localhost → 23514 (H3)');
select throws_ok($$select public.admin_block_domain(repeat('a', 60) || '.' || repeat('b.', 100) || 'com')$$,
  '23514', null, 'admin_block_domain: más de 253 caracteres → 23514');
select pg_temp.logout();

select is(
  array(select row(a.action, a.actor, a.org_id)::text
          from pg_temp.audit_rows('blocked_domain', 'evil.example.com') a),
  array[row('blocked_domain.created', '00000000-0000-0000-0000-0000000000ff'::uuid,
            '00000000-0000-0000-0000-000000000000'::uuid)::text],
  'auditoría: un solo blocked_domain.created (idempotente) en ámbito plataforma');

-- El bloqueo impide crear o redirigir enlaces hacia el dominio y sus subdominios.
select pg_temp.login('00000000-0000-0000-0000-0000000000a1');
select throws_ok(
  $$insert into public.dynamic_links (org_id, name, destination_url)
    values ('0000000a-0000-0000-0000-000000000000', 'X', 'https://evil.example.com/promo')$$,
  '23514', null, 'bloqueado: crear enlace hacia el dominio → 23514');
select throws_ok(
  $$insert into public.dynamic_links (org_id, name, destination_url)
    values ('0000000a-0000-0000-0000-000000000000', 'X', 'https://WWW.Evil.Example.com/')$$,
  '23514', null, 'bloqueado: crear enlace hacia un subdominio → 23514');
select throws_ok(
  $$update public.dynamic_links set destination_url = 'https://evil.example.com/'
     where id = 'a1000000-0000-0000-0000-000000000002'$$,
  '23514', null, 'bloqueado: cambiar el destino al dominio → 23514');
select lives_ok(
  $$insert into public.dynamic_links (org_id, name, destination_url)
    values ('0000000a-0000-0000-0000-000000000000', 'X', 'https://notevil.example.com/')$$,
  'bloqueado: un dominio hermano no se bloquea');
-- Un usuario normal no ve la auditoría de plataforma.
select is((select count(*) from public.audit_log where org_id = '00000000-0000-0000-0000-000000000000'),
  0::bigint, 'RLS: un usuario normal no ve la auditoría de plataforma');
select pg_temp.logout();

select pg_temp.login('00000000-0000-0000-0000-0000000000ff');
select is((select count(*) from public.audit_log where org_id = '00000000-0000-0000-0000-000000000000'),
  2::bigint, 'RLS: el platform admin ve la auditoría de plataforma');
select lives_ok($$select public.admin_unblock_domain(' Evil.Example.com. ')$$,
  'admin_unblock_domain: normaliza la entrada');
select is(
  (select count(*) from public.admin_list_blocked_domains() d where d.domain = 'evil.example.com'),
  0::bigint, 'admin_unblock_domain: el dominio ya no está en la lista');
select throws_ok($$select public.admin_unblock_domain('evil.example.com')$$,
  'P0002', null, 'admin_unblock_domain: dominio no bloqueado → P0002');
select throws_ok($$select public.admin_unblock_domain(null)$$,
  'P0002', null, 'admin_unblock_domain: NULL → P0002');
select pg_temp.logout();

select is(
  array(select a.action from pg_temp.audit_rows('blocked_domain', 'evil.example.com') a),
  array['blocked_domain.created', 'blocked_domain.deleted'],
  'auditoría: blocked_domain.deleted');

select pg_temp.login('00000000-0000-0000-0000-0000000000a1');
select lives_ok(
  $$insert into public.dynamic_links (org_id, name, destination_url)
    values ('0000000a-0000-0000-0000-000000000000', 'X', 'https://evil.example.com/promo')$$,
  'desbloqueado: ya se puede crear el enlace');
select pg_temp.logout();

-- -----------------------------------------------------------------------------
-- Platform admin: enlaces
-- -----------------------------------------------------------------------------
select pg_temp.login('00000000-0000-0000-0000-0000000000ff');
select is(
  (select row(l.id, l.org_id, l.org_name, l.slug, l.name, l.destination_url, l.status)::text
     from public.admin_find_link('AbC1234') l),
  row('a1000000-0000-0000-0000-000000000001'::uuid, '0000000a-0000-0000-0000-000000000000'::uuid,
      'Org A', 'AbC1234', 'Menú', 'https://menu.example.com/', 'active'::public.link_status)::text,
  'admin_find_link: encuentra el enlace con su org');
select is((select count(*) from public.admin_find_link(' AbC1234 ')), 1::bigint,
  'admin_find_link: ignora espacios alrededor');
select is((select count(*) from public.admin_find_link('abc1234')), 0::bigint,
  'admin_find_link: el slug distingue mayúsculas');
select is((select count(*) from public.admin_find_link('Nope000')), 0::bigint,
  'admin_find_link: slug inexistente → sin filas');

select is(
  (select l.status from public.admin_set_link_status('a1000000-0000-0000-0000-000000000001', 'paused') l),
  'paused'::public.link_status, 'admin_set_link_status: suspende (paused)');
select is(
  (select l.status from public.admin_set_link_status('a1000000-0000-0000-0000-000000000001', 'archived') l),
  'archived'::public.link_status, 'admin_set_link_status: archiva');
select is(
  (select l.status from public.admin_set_link_status('a1000000-0000-0000-0000-000000000001', 'active') l),
  'active'::public.link_status, 'admin_set_link_status: reactiva un archivado');
select throws_ok(
  $$select public.admin_set_link_status('a1000000-0000-0000-0000-00000000dead', 'paused')$$,
  'P0002', null, 'admin_set_link_status: enlace inexistente → P0002');
select throws_ok(
  $$select public.admin_set_link_status('a1000000-0000-0000-0000-000000000001', null)$$,
  '22023', null, 'admin_set_link_status: estado NULL → 22023');
select pg_temp.logout();

select is(
  array(select row(a.action, a.actor, a.diff)::text
          from pg_temp.audit_rows('link', 'a1000000-0000-0000-0000-000000000001') a
         where a.action = 'link.status_changed'),
  array[
    row('link.status_changed', '00000000-0000-0000-0000-0000000000ff'::uuid,
        '{"status": {"old": "active", "new": "paused"}}'::jsonb)::text,
    row('link.status_changed', '00000000-0000-0000-0000-0000000000ff'::uuid,
        '{"status": {"old": "paused", "new": "archived"}}'::jsonb)::text,
    row('link.status_changed', '00000000-0000-0000-0000-0000000000ff'::uuid,
        '{"status": {"old": "archived", "new": "active"}}'::jsonb)::text],
  'auditoría: link.status_changed con actor = platform admin');
select is(
  (select row(l.slug, l.org_id, l.destination_url)::text from public.dynamic_links l
    where l.id = 'a1000000-0000-0000-0000-000000000001'),
  row('AbC1234', '0000000a-0000-0000-0000-000000000000'::uuid, 'https://menu.example.com/')::text,
  'admin_set_link_status: solo cambia el estado');

-- El owner de A ve la auditoría de su org generada por el platform admin.
select pg_temp.login('00000000-0000-0000-0000-0000000000a1');
select ok(
  (select count(*) from public.audit_log
    where org_id = '0000000a-0000-0000-0000-000000000000'
      and actor = '00000000-0000-0000-0000-0000000000ff') >= 7,
  'el owner de la org ve las acciones del platform admin en su auditoría');
select pg_temp.logout();

-- -----------------------------------------------------------------------------
-- H1 · Suspensión de enlaces por la plataforma
-- -----------------------------------------------------------------------------
select ok(
  (select not c.convalidated from pg_constraint c
    where c.conname = 'blocked_domains_two_labels_check'
      and c.conrelid = 'private.blocked_domains'::regclass),
  'H3: CHECK de dos etiquetas creado NOT VALID (expand)');
select ok(
  not has_column_privilege('authenticated', 'public.dynamic_links', 'suspended_at', 'update')
  and not has_column_privilege('authenticated', 'public.dynamic_links', 'suspended_reason', 'update')
  and not has_column_privilege('authenticated', 'public.dynamic_links', 'suspended_at', 'insert')
  and not has_column_privilege('authenticated', 'public.dynamic_links', 'suspended_reason', 'insert'),
  'authenticated sin INSERT/UPDATE en suspended_at/suspended_reason');
select ok(has_column_privilege('authenticated', 'public.dynamic_links', 'suspended_at', 'select'),
  'authenticated puede leer suspended_at');
select ok(
  not has_function_privilege('anon', 'public.resolve_link(text)', 'execute')
  and not has_function_privilege('authenticated', 'public.resolve_link(text)', 'execute')
  and has_function_privilege('service_role', 'public.resolve_link(text)', 'execute')
  and (select p.prosecdef and p.proconfig = array['search_path=""']
         from pg_proc p where p.oid = 'public.resolve_link(text)'::regprocedure),
  'resolve_link recreada: SECURITY DEFINER, search_path vacío, solo service_role');

-- La org no puede suspender por su cuenta (ni con UPDATE ni con INSERT).
select pg_temp.login('00000000-0000-0000-0000-0000000000a1');
select throws_ok(
  $$update public.dynamic_links set suspended_at = now()
     where id = 'a1000000-0000-0000-0000-000000000002'$$,
  '42501', null, 'owner: UPDATE de suspended_at → 42501');
select throws_ok(
  $$insert into public.dynamic_links (org_id, name, destination_url, suspended_at)
    values ('0000000a-0000-0000-0000-000000000000', 'S', 'https://s.example.com/', now())$$,
  '42501', null, 'owner: INSERT con suspended_at → 42501');
select pg_temp.logout();

-- Ni el platform admin por la tabla (debe usar la RPC).
select pg_temp.login('00000000-0000-0000-0000-0000000000ff');
select throws_ok(
  $$update public.dynamic_links set suspended_reason = 'x'
     where id = 'a1000000-0000-0000-0000-000000000002'$$,
  '42501', null, 'platform admin: UPDATE directo de suspended_reason → 42501 (usa la RPC)');

select is(
  (select row(l.suspended_at is not null, l.suspended_reason, l.status)::text
     from public.admin_suspend_link('a1000000-0000-0000-0000-000000000002', true, '  Phishing  ') l),
  row(true, 'Phishing', 'active'::public.link_status)::text,
  'admin_suspend_link: suspende con motivo (btrim) sin tocar status');
select pg_temp.logout();

create temp table t051_susp as
  select suspended_at from public.dynamic_links where id = 'a1000000-0000-0000-0000-000000000002';
grant select on t051_susp to authenticated, service_role;

select is(
  array(select row(a.action, a.actor, a.diff -> 'suspended_reason')::text
          from pg_temp.audit_rows('link', 'a1000000-0000-0000-0000-000000000002') a
         where a.action <> 'link.created'),
  array[row('link.suspended', '00000000-0000-0000-0000-0000000000ff'::uuid,
            '{"old": null, "new": "Phishing"}'::jsonb)::text],
  'auditoría: solo link.suspended (sin link.updated duplicado), actor = platform admin');

-- La org no puede tocar un enlace suspendido.
select pg_temp.login('00000000-0000-0000-0000-0000000000a1');
select throws_ok(
  $$update public.dynamic_links set status = 'paused'
     where id = 'a1000000-0000-0000-0000-000000000002'$$,
  '42501', null, 'owner: cambiar status de un enlace suspendido → 42501');
select throws_ok(
  $$update public.dynamic_links set destination_url = 'https://otro.example.com/'
     where id = 'a1000000-0000-0000-0000-000000000002'$$,
  '42501', null, 'owner: cambiar destino de un enlace suspendido → 42501');
select throws_ok(
  $$update public.dynamic_links set fallback_url = 'https://otro.example.com/'
     where id = 'a1000000-0000-0000-0000-000000000002'$$,
  '42501', null, 'owner: cambiar fallback de un enlace suspendido → 42501');
select throws_ok(
  $$update public.dynamic_links set name = 'Otro'
     where id = 'a1000000-0000-0000-0000-000000000002'$$,
  '42501', null, 'owner: renombrar un enlace suspendido → 42501');
select is((select suspended_reason from public.dynamic_links where id = 'a1000000-0000-0000-0000-000000000002'),
  'Phishing', 'owner: ve el motivo de la suspensión');
select lives_ok(
  $$update public.dynamic_links set name = 'Menú 2'
     where id = 'a1000000-0000-0000-0000-000000000001'$$,
  'owner: los enlaces no suspendidos se siguen editando');
select pg_temp.logout();

select pg_temp.login('00000000-0000-0000-0000-0000000000ed');
select throws_ok(
  $$update public.dynamic_links set status = 'active'
     where id = 'a1000000-0000-0000-0000-000000000002'$$,
  '42501', null, 'editor: tocar un enlace suspendido → 42501');
select pg_temp.logout();

-- El redirector lo ve suspendido.
set local role service_role;
select is(
  (select r.suspended_at from public.resolve_link('XyZ9876') r),
  (select suspended_at from t051_susp),
  'resolve_link devuelve suspended_at del enlace suspendido');
select is(
  (select r.suspended_at from public.resolve_link('AbC1234') r), null::timestamptz,
  'resolve_link: suspended_at NULL en un enlace no suspendido');
select lives_ok(
  $$update public.dynamic_links set name = 'Promo (svc)'
     where id = 'a1000000-0000-0000-0000-000000000002'$$,
  'service_role puede modificar un enlace suspendido');
reset role;

select pg_temp.login('00000000-0000-0000-0000-0000000000ff');
select is(
  (select row(l.suspended_at = (select suspended_at from t051_susp), l.suspended_reason)::text
     from public.admin_suspend_link('a1000000-0000-0000-0000-000000000002', true, 'Malware') l),
  row(true, 'Malware')::text,
  'admin_suspend_link: re-suspender conserva suspended_at y cambia el motivo');
select lives_ok($$select public.admin_suspend_link('a1000000-0000-0000-0000-000000000002', true, 'Malware')$$,
  'admin_suspend_link: repetir sin cambios es idempotente');
select throws_ok(
  $$select public.admin_suspend_link('a1000000-0000-0000-0000-000000000002', true, repeat('x', 501))$$,
  '23514', null, 'admin_suspend_link: motivo > 500 → 23514');
select throws_ok(
  $$select public.admin_suspend_link('a1000000-0000-0000-0000-00000000dead', true)$$,
  'P0002', null, 'admin_suspend_link: enlace inexistente → P0002');
select throws_ok(
  $$select public.admin_suspend_link('a1000000-0000-0000-0000-000000000002', null)$$,
  '22023', null, 'admin_suspend_link: p_suspended NULL → 22023');
select is(
  (select row(l.suspended_at, l.suspended_reason)::text
     from public.admin_suspend_link('a1000000-0000-0000-0000-000000000002', false, 'ignorado') l),
  row(null::timestamptz, null::text)::text,
  'admin_suspend_link: reactivar limpia suspended_at y el motivo');
select lives_ok($$select public.admin_suspend_link('a1000000-0000-0000-0000-000000000001', false)$$,
  'admin_suspend_link: reactivar un enlace no suspendido no falla');
select pg_temp.logout();

select is(
  array(select a.action
          from pg_temp.audit_rows('link', 'a1000000-0000-0000-0000-000000000002') a
         where a.action in ('link.suspended', 'link.unsuspended', 'link.updated')),
  array['link.suspended', 'link.updated', 'link.suspended', 'link.unsuspended'],
  'auditoría: suspended, edición de service_role, cambio de motivo y unsuspended; sin filas por no-ops');
select is(
  (select count(*) from pg_temp.audit_rows('link', 'a1000000-0000-0000-0000-000000000001') a
    where a.action like 'link.%suspended'),
  0::bigint, 'auditoría: reactivar un enlace no suspendido no deja fila');

select pg_temp.login('00000000-0000-0000-0000-0000000000a1');
select lives_ok(
  $$update public.dynamic_links set status = 'paused'
     where id = 'a1000000-0000-0000-0000-000000000002'$$,
  'owner: tras reactivar, vuelve a poder editar el enlace');
select pg_temp.logout();

-- -----------------------------------------------------------------------------
-- Platform admin también puede operar sobre la org vía tablas (sin regresión)
-- y my_effective_role no da acceso a quien deja de ser platform admin.
-- -----------------------------------------------------------------------------
delete from public.platform_admins where user_id = '00000000-0000-0000-0000-0000000000ff';
select pg_temp.login('00000000-0000-0000-0000-0000000000ff');
select is(public.my_effective_role('0000000a-0000-0000-0000-000000000000'), null::public.org_role,
  'ex platform admin: my_effective_role → NULL');
select throws_ok($$select * from public.admin_list_orgs()$$,
  '42501', null, 'ex platform admin: admin_list_orgs → 42501');
select pg_temp.logout();

select * from finish(true);
rollback;
