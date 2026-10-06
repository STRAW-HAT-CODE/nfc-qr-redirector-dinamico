-- =============================================================================
-- DQR-T041 · Rollups diarios de escaneos: scan_daily_rollups + pg_cron
-- Módulo DQR-06 (analytics) · docs/03-modelo-datos.md (scan_daily_rollups) ·
-- docs/06-seguridad.md (métricas: bots excluidos) · sec-T022 H7 (las
-- estadísticas de rango van por rollups, filtrando por link_id/org_id).
--
-- Fase: EXPAND (añade objetos; depende de 20261006022927_scan_events.sql).
--   Único cambio sobre algo existente: la política scan_events_select pasa a
--   evaluarse por conjunto (alter policy), con la misma semántica.
--
-- Decisiones:
--   * Día = fecha UTC de occurred_at. Una fila por (enlace, día) con al menos
--     un escaneo humano; los bots (is_bot) no cuentan en ninguna columna.
--   * unique_visitors = count(distinct ip_hash) del día por enlace. La sal del
--     hash rota a diario (T023), así que ip_hash ya identifica "IP + día".
--     ip_hash NULL no cuenta como visitante único (sí como escaneo).
--     docs/06 habla de "ip_hash + UA"; hoy no se guarda el UA en claro (solo
--     device/os/browser), así que se usa solo ip_hash (decisión del
--     orquestador para T041).
--   * Coherencia de org: FK compuesta (link_id, org_id) → dynamic_links
--     (id, org_id) on delete cascade, como scan_events.
--   * Escritura: solo private.refresh_scan_rollups() (SECURITY DEFINER,
--     EXECUTE solo service_role) y service_role. authenticated solo lee
--     (RLS: miembros de la org —viewer+— y platform admin). anon nada.
--   * Idempotencia: refresh recalcula el rango desde scan_events y hace upsert
--     (solo toca filas que cambian) y borra las filas del rango que ya no
--     tienen escaneos. Llamarlo N veces deja el mismo resultado.
--   * Marca de agua (private.scan_rollup_state.closed_through): último día UTC
--     cuyo rollup se calculó cuando el día ya había terminado y sin huecos
--     desde la marca anterior. Las métricas leen rollups hasta esa fecha y
--     cuentan en vivo después (normalmente solo hoy). Si el job se para, los
--     números siguen siendo correctos (más días en vivo, más lentos).
--   * Job pg_cron cada 15 min: private.run_scan_rollups() recalcula desde
--     min(marca + 1, ayer) hasta hoy, como máximo 32 días por pasada, así que
--     se pone al día solo tras una caída.
--   * Métricas para T042: public.link_stats / public.org_stats, SECURITY
--     INVOKER (respetan la RLS de scan_daily_rollups y scan_events). Filas
--     solo para días con escaneos (dispersas); la API rellena con ceros.
--     org_stats.unique_visitors es la SUMA de los únicos por enlace (un mismo
--     visitante en dos enlaces cuenta dos veces), también en el tramo en vivo,
--     para que todos los días tengan la misma semántica.
--   * Guardas (sec-T041 H1): link_stats/org_stats salen sin leer nada si el
--     usuario no ve el enlace / no es miembro ni platform admin.
--   * RLS por conjunto (sec-T041 H2): private.my_org_ids(); se cambia también
--     la política scan_events_select de T022 (alter policy, misma semántica).
--   * Índices: PK (link_id, day) sirve link_stats y la FK; (org_id, day) sirve
--     org_stats y la RLS; (day) sirve el barrido por rango del refresh. El
--     tramo en vivo usa los índices de scan_events (link_id|org_id,
--     occurred_at) y el BRIN (occurred_at) del refresh.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- Tabla
-- -----------------------------------------------------------------------------
create table public.scan_daily_rollups (
  link_id          uuid not null,
  org_id           uuid not null,
  day              date not null,
  scans            integer not null,
  unique_visitors  integer not null,
  qr               integer not null,
  nfc              integer not null,
  direct           integer not null,
  updated_at       timestamptz not null default now(),
  constraint scan_daily_rollups_pkey primary key (link_id, day),
  constraint scan_daily_rollups_link_org_fkey
    foreign key (link_id, org_id)
    references public.dynamic_links (id, org_id)
    on delete cascade,
  constraint scan_daily_rollups_counts_check
    check (
      scans > 0
      and qr >= 0 and nfc >= 0 and direct >= 0
      and qr + nfc + direct = scans
      and unique_visitors between 0 and scans
    )
);
comment on table public.scan_daily_rollups is
  'Escaneos humanos (sin bots) por enlace y día UTC. Escribe private.refresh_scan_rollups() (pg_cron); leen los miembros de la org. DQR-06.';
comment on column public.scan_daily_rollups.day is 'Día UTC de scan_events.occurred_at.';
comment on column public.scan_daily_rollups.unique_visitors is
  'count(distinct ip_hash) del día (la sal rota a diario). ip_hash NULL no cuenta.';

create index scan_daily_rollups_org_day_idx on public.scan_daily_rollups (org_id, day);
create index scan_daily_rollups_day_idx on public.scan_daily_rollups (day);

-- -----------------------------------------------------------------------------
-- Estado del rollup (marca de agua). Fila única; no es dato de negocio.
-- -----------------------------------------------------------------------------
create table private.scan_rollup_state (
  id              boolean primary key default true,
  closed_through  date,
  updated_at      timestamptz not null default now(),
  constraint scan_rollup_state_singleton check (id)
);
comment on table private.scan_rollup_state is
  'Marca de agua de scan_daily_rollups: días ≤ closed_through están cerrados y completos. DQR-T041.';

insert into private.scan_rollup_state (id, closed_through) values (true, null);

revoke all on private.scan_rollup_state from public, anon, authenticated;
grant select on private.scan_rollup_state to service_role;

-- -----------------------------------------------------------------------------
-- Recalcular rollups de un rango de días (idempotente)
-- -----------------------------------------------------------------------------
-- Errores: 22023 hint invalid_range · p_from/p_to nulos o p_from > p_to.
-- Devuelve el número de filas insertadas/actualizadas/borradas.
create or replace function private.refresh_scan_rollups(p_from date, p_to date)
returns integer
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_today    date := (now() at time zone 'UTC')::date;
  v_from_ts  timestamptz;
  v_to_ts    timestamptz;
  v_upserted integer;
  v_deleted  integer;
  v_closed   date;
begin
  if p_from is null or p_to is null or p_from > p_to then
    raise exception 'refresh_scan_rollups: rango no válido'
      using errcode = '22023', hint = 'invalid_range';
  end if;

  -- Un refresh a la vez (job y backfill manual no se pisan).
  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtext('dqr.refresh_scan_rollups'));

  v_from_ts := p_from::timestamp at time zone 'UTC';
  v_to_ts   := (p_to + 1)::timestamp at time zone 'UTC';

  with agg as (
    select
      e.link_id,
      e.org_id,
      (e.occurred_at at time zone 'UTC')::date                 as day,
      count(*)::integer                                         as scans,
      count(distinct e.ip_hash)::integer                        as unique_visitors,
      (count(*) filter (where e.channel = 'qr'))::integer       as qr,
      (count(*) filter (where e.channel = 'nfc'))::integer      as nfc,
      (count(*) filter (where e.channel = 'direct'))::integer   as direct
    from public.scan_events e
    where e.occurred_at >= v_from_ts
      and e.occurred_at < v_to_ts
      and not e.is_bot
    group by e.link_id, e.org_id, (e.occurred_at at time zone 'UTC')::date
  ),
  upserted as (
    insert into public.scan_daily_rollups as r
      (link_id, org_id, day, scans, unique_visitors, qr, nfc, direct, updated_at)
    select a.link_id, a.org_id, a.day, a.scans, a.unique_visitors, a.qr, a.nfc, a.direct, now()
    from agg a
    on conflict (link_id, day) do update
      set scans           = excluded.scans,
          unique_visitors = excluded.unique_visitors,
          qr              = excluded.qr,
          nfc             = excluded.nfc,
          direct          = excluded.direct,
          updated_at      = excluded.updated_at
      where (r.scans, r.unique_visitors, r.qr, r.nfc, r.direct)
        is distinct from
            (excluded.scans, excluded.unique_visitors, excluded.qr, excluded.nfc, excluded.direct)
    returning 1
  ),
  deleted as (
    delete from public.scan_daily_rollups r
    where r.day between p_from and p_to
      and not exists (
        select 1 from agg a where a.link_id = r.link_id and a.day = r.day
      )
    returning 1
  )
  select (select count(*) from upserted), (select count(*) from deleted)
  into v_upserted, v_deleted;

  -- Marca de agua: avanza hasta el último día ya terminado del rango, solo si
  -- el rango empieza en o antes de marca + 1 (sin huecos).
  v_closed := least(p_to, v_today - 1);
  update private.scan_rollup_state s
     set closed_through = v_closed,
         updated_at     = now()
   where s.id
     and v_closed >= p_from
     and (s.closed_through is null
          or (p_from <= s.closed_through + 1 and v_closed > s.closed_through));

  return v_upserted + v_deleted;
end;
$$;

comment on function private.refresh_scan_rollups(date, date) is
  'Recalcula scan_daily_rollups para [p_from, p_to] (días UTC) desde scan_events, sin bots. Idempotente. DQR-T041.';

alter function private.refresh_scan_rollups(date, date) owner to postgres;
revoke execute on function private.refresh_scan_rollups(date, date) from public, anon, authenticated;
grant execute on function private.refresh_scan_rollups(date, date) to service_role;

-- -----------------------------------------------------------------------------
-- Pasada del job: desde min(marca + 1, ayer) hasta hoy, máximo 32 días
-- -----------------------------------------------------------------------------
create or replace function private.run_scan_rollups()
returns integer
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_today  date := (now() at time zone 'UTC')::date;
  v_closed date;
  v_from   date;
begin
  select s.closed_through into v_closed from private.scan_rollup_state s where s.id;
  v_from := least(coalesce(v_closed + 1, v_today - 1), v_today - 1);
  return private.refresh_scan_rollups(v_from, least(v_from + 31, v_today));
end;
$$;

comment on function private.run_scan_rollups() is
  'Job pg_cron (cada 15 min): recalcula ayer y hoy, o se pone al día desde la marca de agua (≤ 32 días por pasada). DQR-T041.';

alter function private.run_scan_rollups() owner to postgres;
revoke execute on function private.run_scan_rollups() from public, anon, authenticated;
grant execute on function private.run_scan_rollups() to service_role;

-- -----------------------------------------------------------------------------
-- Marca de agua legible por las funciones de métricas (no es sensible)
-- -----------------------------------------------------------------------------
create or replace function private.scan_rollups_closed_through()
returns date
language sql
stable
security definer
set search_path = ''
as $$
  select s.closed_through from private.scan_rollup_state s where s.id;
$$;

alter function private.scan_rollups_closed_through() owner to postgres;
revoke execute on function private.scan_rollups_closed_through() from public, anon;
grant execute on function private.scan_rollups_closed_through() to authenticated, service_role;

-- -----------------------------------------------------------------------------
-- Métricas por rango (T042). SECURITY INVOKER: la RLS decide qué filas se ven.
-- -----------------------------------------------------------------------------
-- Errores: 22023 hint invalid_range · nulos, p_from > p_to o más de 366 días.
-- Devuelve una fila por día UTC con escaneos (sin bots), ordenada por día.
create or replace function public.link_stats(p_link_id uuid, p_from date, p_to date)
returns table (
  day             date,
  scans           integer,
  unique_visitors integer,
  qr              integer,
  nfc             integer,
  direct          integer
)
language plpgsql
stable
security invoker
set search_path = ''
as $$
#variable_conflict use_column
declare
  v_closed date;
  v_live   date;
begin
  if p_link_id is null or p_from is null or p_to is null
     or p_from > p_to or p_to - p_from > 365 then
    raise exception 'link_stats: rango no válido (máximo 366 días)'
      using errcode = '22023', hint = 'invalid_range';
  end if;

  -- sec-T041 H1: salida temprana si el enlace no es visible (dynamic_links
  -- tiene RLS: solo lo ven los miembros y el platform admin). Evita que un
  -- extraño obligue a recorrer los datos de otra org.
  if not exists (select 1 from public.dynamic_links l where l.id = p_link_id) then
    return;
  end if;

  v_closed := private.scan_rollups_closed_through();
  v_live   := greatest(p_from, coalesce(v_closed + 1, p_from));

  return query
  select r.day, r.scans, r.unique_visitors, r.qr, r.nfc, r.direct
  from public.scan_daily_rollups r
  where r.link_id = p_link_id
    and v_closed is not null
    and r.day >= p_from
    and r.day <= least(p_to, v_closed)
  union all
  select
    (e.occurred_at at time zone 'UTC')::date,
    count(*)::integer,
    count(distinct e.ip_hash)::integer,
    (count(*) filter (where e.channel = 'qr'))::integer,
    (count(*) filter (where e.channel = 'nfc'))::integer,
    (count(*) filter (where e.channel = 'direct'))::integer
  from public.scan_events e
  where e.link_id = p_link_id
    and v_live <= p_to
    and e.occurred_at >= v_live::timestamp at time zone 'UTC'
    and e.occurred_at < (p_to + 1)::timestamp at time zone 'UTC'
    and not e.is_bot
  group by 1
  order by 1;
end;
$$;

comment on function public.link_stats(uuid, date, date) is
  'Escaneos por día UTC de un enlace (rollups cerrados + conteo en vivo). Sin bots. Respeta RLS. DQR-T041/T042.';

revoke execute on function public.link_stats(uuid, date, date) from public, anon;
grant execute on function public.link_stats(uuid, date, date) to authenticated, service_role;

create or replace function public.org_stats(p_org_id uuid, p_from date, p_to date)
returns table (
  day             date,
  scans           integer,
  unique_visitors integer,
  qr              integer,
  nfc             integer,
  direct          integer
)
language plpgsql
stable
security invoker
set search_path = ''
as $$
#variable_conflict use_column
declare
  v_closed date;
  v_live   date;
begin
  if p_org_id is null or p_from is null or p_to is null
     or p_from > p_to or p_to - p_from > 365 then
    raise exception 'org_stats: rango no válido (máximo 366 días)'
      using errcode = '22023', hint = 'invalid_range';
  end if;

  -- sec-T041 H1: salida temprana si no es miembro ni platform admin.
  if not (private.is_org_member(p_org_id) or (select private.is_platform_admin())) then
    return;
  end if;

  v_closed := private.scan_rollups_closed_through();
  v_live   := greatest(p_from, coalesce(v_closed + 1, p_from));

  return query
  select t.day, sum(t.scans)::integer, sum(t.unique_visitors)::integer,
         sum(t.qr)::integer, sum(t.nfc)::integer, sum(t.direct)::integer
  from (
    select r.day, r.scans, r.unique_visitors, r.qr, r.nfc, r.direct
    from public.scan_daily_rollups r
    where r.org_id = p_org_id
      and v_closed is not null
      and r.day >= p_from
      and r.day <= least(p_to, v_closed)
    union all
    -- En vivo: por enlace y día, para sumar únicos igual que en los rollups.
    select
      (e.occurred_at at time zone 'UTC')::date,
      count(*),
      count(distinct e.ip_hash),
      count(*) filter (where e.channel = 'qr'),
      count(*) filter (where e.channel = 'nfc'),
      count(*) filter (where e.channel = 'direct')
    from public.scan_events e
    where e.org_id = p_org_id
      and v_live <= p_to
      and e.occurred_at >= v_live::timestamp at time zone 'UTC'
      and e.occurred_at < (p_to + 1)::timestamp at time zone 'UTC'
      and not e.is_bot
    group by e.link_id, 1
  ) t
  group by t.day
  order by t.day;
end;
$$;

comment on function public.org_stats(uuid, date, date) is
  'Escaneos por día UTC de una organización (rollups cerrados + conteo en vivo). Sin bots. unique_visitors = suma de únicos por enlace. Respeta RLS. DQR-T041/T042.';

revoke execute on function public.org_stats(uuid, date, date) from public, anon;
grant execute on function public.org_stats(uuid, date, date) to authenticated, service_role;

-- -----------------------------------------------------------------------------
-- Privilegios de tabla (explícitos; RLS filtra filas)
-- -----------------------------------------------------------------------------
revoke all on public.scan_daily_rollups from anon, authenticated;
grant select on public.scan_daily_rollups to authenticated;
grant select, insert, update, delete on public.scan_daily_rollups to service_role;

-- -----------------------------------------------------------------------------
-- sec-T041 H2: orgs del usuario como conjunto. Las políticas usan
-- org_id in (select private.my_org_ids()), que se evalúa una vez por consulta
-- (subplan hasheado) en lugar de llamar a is_org_member() fila a fila.
-- -----------------------------------------------------------------------------
create or replace function private.my_org_ids()
returns setof uuid
language sql
stable
security definer
set search_path = ''
as $$
  select m.org_id from public.memberships m where m.user_id = (select auth.uid())
$$;

comment on function private.my_org_ids() is
  'Organizaciones del usuario actual (auth.uid()). Para políticas RLS de lectura por conjunto. DQR-T041 / sec-T041 H2.';

alter function private.my_org_ids() owner to postgres;
revoke execute on function private.my_org_ids() from public, anon;
grant execute on function private.my_org_ids() to authenticated;

-- -----------------------------------------------------------------------------
-- RLS: solo lectura para miembros (viewer+) y platform admin; sin políticas
-- de escritura (escriben la función SECURITY DEFINER y service_role).
-- -----------------------------------------------------------------------------
alter table public.scan_daily_rollups enable row level security;

create policy scan_daily_rollups_select
  on public.scan_daily_rollups for select
  to authenticated
  using (
    org_id in (select private.my_org_ids())
    or (select private.is_platform_admin())
  );

-- Misma semántica que la política de T022 (miembro de la org o platform
-- admin), evaluada por conjunto (sec-T041 H2).
alter policy scan_events_select on public.scan_events
  using (
    org_id in (select private.my_org_ids())
    or (select private.is_platform_admin())
  );

-- -----------------------------------------------------------------------------
-- Backfill inicial (cierra la marca de agua en ayer)
-- -----------------------------------------------------------------------------
select private.refresh_scan_rollups(
  coalesce(
    (select (min(e.occurred_at) at time zone 'UTC')::date from public.scan_events e),
    (now() at time zone 'UTC')::date - 1
  ),
  (now() at time zone 'UTC')::date
);

-- -----------------------------------------------------------------------------
-- pg_cron: job cada 15 min (idempotente). En Supabase pg_cron está disponible
-- (docs: create extension pg_cron with schema pg_catalog). Si la imagen local
-- no lo trae o no está precargado, se avisa y la migración sigue.
-- -----------------------------------------------------------------------------
do $$
begin
  if not exists (select 1 from pg_catalog.pg_available_extensions where name = 'pg_cron') then
    raise warning 'DQR-T041: pg_cron no disponible; job dqr_scan_rollups sin programar';
    return;
  end if;

  begin
    create extension if not exists pg_cron with schema pg_catalog;
  exception when others then
    raise warning 'DQR-T041: no se pudo habilitar pg_cron (%); job sin programar', sqlerrm;
    return;
  end;

  perform cron.unschedule(j.jobid) from cron.job j where j.jobname = 'dqr_scan_rollups';
  perform cron.schedule('dqr_scan_rollups', '*/15 * * * *', 'select private.run_scan_rollups()');
end;
$$;
