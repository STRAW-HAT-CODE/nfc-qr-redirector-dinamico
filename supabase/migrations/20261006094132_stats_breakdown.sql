-- =============================================================================
-- DQR-T042 (parte BD) · Desglose de métricas por dimensión:
--   public.link_breakdown / public.org_breakdown
-- Módulo DQR-06 (analytics) · docs/04-api.md (group=channel|country|device) ·
-- docs/06-seguridad.md (métricas: bots excluidos) · sec-T041 H1/H2.
--
-- Fase: EXPAND (solo añade dos funciones; depende de
--   20261006045157_scan_rollups.sql por private.my_org_ids y la RLS por conjunto).
--
-- Motivo: en Supabase los agregados de PostgREST (select=col,scans:count())
--   están desactivados y no se van a activar (decisión del orquestador), así
--   que la API pide el desglose por RPC.
--
-- Decisiones:
--   * Dimensiones (lista blanca): country, device, os, browser, channel,
--     referer. Se elige la columna con un CASE sobre el parámetro, sin SQL
--     dinámico. Cualquier otro valor (o NULL) → 22023 hint invalid_dimension.
--   * Rango en días UTC [p_from, p_to], como link_stats/org_stats: from ≤ to,
--     como mucho 366 días, sin nulos ni ±infinity → 22023 hint invalid_range.
--   * Fuente: scan_events en vivo (los rollups diarios no guardan dimensiones).
--     Bots (is_bot) excluidos.
--   * Salida: top 20 valores por escaneos (desempate por valor, collation "C"), ordenados de
--     mayor a menor, y al final una fila 'other' con la suma del resto (solo si
--     hay resto). NULL → 'unknown', que compite en el top como un valor más.
--     Nombres reservados: un valor guardado literalmente como 'other' (T040 lo
--     usa en device) se suma a la fila 'other' y nunca entra en el top, para
--     no devolver dos filas con el mismo nombre; 'unknown' literal se junta con
--     NULL (T040 ya convierte 'unknown' en NULL).
--   * unique_visitors: visitantes distintos por (enlace, día UTC), igual que
--     scan_daily_rollups (la sal de ip_hash rota a diario, T023) y sumados
--     sobre enlaces y días, como org_stats. ip_hash NULL no cuenta. En la fila
--     'other' es la suma de los únicos de cada valor agrupado.
--   * Seguridad: SECURITY INVOKER (la RLS de scan_events filtra) + guarda de
--     pertenencia de sec-T041 H1: si el usuario no ve el enlace / no es
--     miembro ni platform admin, sale sin leer scan_events. STABLE,
--     search_path=''. EXECUTE: authenticated y service_role; nunca anon.
--     La API debe llamarlas con el JWT del usuario (sec-T041 H5).
--   * Índices: no se añade ninguno. link_breakdown usa
--     scan_events_link_occurred_idx (link_id, occurred_at desc) y
--     org_breakdown scan_events_org_occurred_idx (org_id, occurred_at desc).
--     Medido (1 M eventos en 90 días, una org con 100 enlaces; un enlace con
--     100 k): un índice cubriente (link_id|org_id, occurred_at) include
--     (is_bot, ip_hash, <6 dimensiones>) baja la lectura del enlace de 156 a
--     32 ms, pero la llamada completa solo de 270 a 251 ms (org 90 d: sin
--     cambio, ~750 ms). El coste está en la agregación, no en la lectura, y
--     los dos índices pesan 280 MB (1,7 veces el heap) y encarecen el insert
--     del redirector un 16 %. Por eso no se crean. Si hace falta < 200 ms
--     con volúmenes así, la vía es un rollup diario por dimensión
--     (seguimiento).
--   * Agregación en dos niveles (valor, enlace, día, ip_hash) → valor en
--     lugar de count(distinct (…)): org 90 d de 1,9 s a 0,75 s en la misma
--     prueba.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- Desglose de un enlace
-- -----------------------------------------------------------------------------
-- Errores: 22023 hint invalid_range · 22023 hint invalid_dimension.
create or replace function public.link_breakdown(
  p_link_id   uuid,
  p_from      date,
  p_to        date,
  p_dimension text
)
returns table (
  value           text,
  scans           bigint,
  unique_visitors bigint
)
language plpgsql
stable
security invoker
set search_path = ''
as $$
#variable_conflict use_column
begin
  if p_link_id is null or p_from is null or p_to is null
     or not pg_catalog.isfinite(p_from) or not pg_catalog.isfinite(p_to)
     or p_from > p_to or p_to - p_from > 365 then
    raise exception 'link_breakdown: rango no válido (máximo 366 días)'
      using errcode = '22023', hint = 'invalid_range';
  end if;

  if p_dimension is null
     or p_dimension not in ('country', 'device', 'os', 'browser', 'channel', 'referer') then
    raise exception 'link_breakdown: dimensión no válida'
      using errcode = '22023', hint = 'invalid_dimension';
  end if;

  -- sec-T041 H1: salida temprana si el enlace no es visible (RLS de
  -- dynamic_links: solo miembros y platform admin).
  if not exists (select 1 from public.dynamic_links l where l.id = p_link_id) then
    return;
  end if;

  return query
  with base as (
    select
      case
        when d.v is null or d.v = 'unknown' then 'unknown'
        else d.v
      end as v,
      d.link_id,
      d.day,
      d.ip_hash
    from (
      select
        case p_dimension
          when 'country' then e.country::text
          when 'device'  then e.device
          when 'os'      then e.os
          when 'browser' then e.browser
          when 'channel' then e.channel::text
          when 'referer' then e.referer
        end as v,
        e.link_id,
        (e.occurred_at at time zone 'UTC')::date as day,
        e.ip_hash
      from public.scan_events e
      where e.link_id = p_link_id
        and e.occurred_at >= p_from::timestamp at time zone 'UTC'
        and e.occurred_at < (p_to + 1)::timestamp at time zone 'UTC'
        and not e.is_bot
    ) d
  ),
  -- Dos niveles en lugar de count(distinct …): un grupo por (valor, enlace,
  -- día, ip_hash) y luego por valor. Únicos = grupos con ip_hash no nulo.
  per_value as (
    select g.v, sum(g.n)::bigint as scans, count(g.ip_hash) as uv
    from (
      select b.v, b.link_id, b.day, b.ip_hash, count(*) as n
      from base b
      group by b.v, b.link_id, b.day, b.ip_hash
    ) g
    group by g.v
  ),
  ranked as (
    select p.v, p.scans, p.uv,
           row_number() over (order by p.scans desc, p.v collate "C") as rn
    from per_value p
    where p.v <> 'other'
  ),
  rest as (
    select r.scans, r.uv from ranked r where r.rn > 20
    union all
    select p.scans, p.uv from per_value p where p.v = 'other'
  )
  select o.v, o.scans, o.uv
  from (
    select r.v, r.scans, r.uv, r.rn as ord from ranked r where r.rn <= 20
    union all
    select 'other', sum(x.scans)::bigint, sum(x.uv)::bigint, 21
    from rest x
    having count(*) > 0
  ) o
  order by o.ord;
end;
$$;

comment on function public.link_breakdown(uuid, date, date, text) is
  'Escaneos y únicos de un enlace por dimensión (country|device|os|browser|channel|referer) en días UTC [from, to] (≤ 366). Top 20 + other; NULL → unknown. Sin bots. Respeta RLS. DQR-T042.';

revoke execute on function public.link_breakdown(uuid, date, date, text) from public, anon;
grant execute on function public.link_breakdown(uuid, date, date, text) to authenticated, service_role;

-- -----------------------------------------------------------------------------
-- Desglose de una organización
-- -----------------------------------------------------------------------------
-- Errores: 22023 hint invalid_range · 22023 hint invalid_dimension.
create or replace function public.org_breakdown(
  p_org_id    uuid,
  p_from      date,
  p_to        date,
  p_dimension text
)
returns table (
  value           text,
  scans           bigint,
  unique_visitors bigint
)
language plpgsql
stable
security invoker
set search_path = ''
as $$
#variable_conflict use_column
begin
  if p_org_id is null or p_from is null or p_to is null
     or not pg_catalog.isfinite(p_from) or not pg_catalog.isfinite(p_to)
     or p_from > p_to or p_to - p_from > 365 then
    raise exception 'org_breakdown: rango no válido (máximo 366 días)'
      using errcode = '22023', hint = 'invalid_range';
  end if;

  if p_dimension is null
     or p_dimension not in ('country', 'device', 'os', 'browser', 'channel', 'referer') then
    raise exception 'org_breakdown: dimensión no válida'
      using errcode = '22023', hint = 'invalid_dimension';
  end if;

  -- sec-T041 H1: salida temprana si no es miembro ni platform admin.
  if not (private.is_org_member(p_org_id) or (select private.is_platform_admin())) then
    return;
  end if;

  return query
  with base as (
    select
      case
        when d.v is null or d.v = 'unknown' then 'unknown'
        else d.v
      end as v,
      d.link_id,
      d.day,
      d.ip_hash
    from (
      select
        case p_dimension
          when 'country' then e.country::text
          when 'device'  then e.device
          when 'os'      then e.os
          when 'browser' then e.browser
          when 'channel' then e.channel::text
          when 'referer' then e.referer
        end as v,
        e.link_id,
        (e.occurred_at at time zone 'UTC')::date as day,
        e.ip_hash
      from public.scan_events e
      where e.org_id = p_org_id
        and e.occurred_at >= p_from::timestamp at time zone 'UTC'
        and e.occurred_at < (p_to + 1)::timestamp at time zone 'UTC'
        and not e.is_bot
    ) d
  ),
  -- Dos niveles en lugar de count(distinct …): un grupo por (valor, enlace,
  -- día, ip_hash) y luego por valor. Únicos = grupos con ip_hash no nulo.
  per_value as (
    select g.v, sum(g.n)::bigint as scans, count(g.ip_hash) as uv
    from (
      select b.v, b.link_id, b.day, b.ip_hash, count(*) as n
      from base b
      group by b.v, b.link_id, b.day, b.ip_hash
    ) g
    group by g.v
  ),
  ranked as (
    select p.v, p.scans, p.uv,
           row_number() over (order by p.scans desc, p.v collate "C") as rn
    from per_value p
    where p.v <> 'other'
  ),
  rest as (
    select r.scans, r.uv from ranked r where r.rn > 20
    union all
    select p.scans, p.uv from per_value p where p.v = 'other'
  )
  select o.v, o.scans, o.uv
  from (
    select r.v, r.scans, r.uv, r.rn as ord from ranked r where r.rn <= 20
    union all
    select 'other', sum(x.scans)::bigint, sum(x.uv)::bigint, 21
    from rest x
    having count(*) > 0
  ) o
  order by o.ord;
end;
$$;

comment on function public.org_breakdown(uuid, date, date, text) is
  'Escaneos y únicos de una organización por dimensión (country|device|os|browser|channel|referer) en días UTC [from, to] (≤ 366). Top 20 + other; NULL → unknown. unique_visitors = suma de únicos por enlace y día. Sin bots. Respeta RLS. DQR-T042.';

revoke execute on function public.org_breakdown(uuid, date, date, text) from public, anon;
grant execute on function public.org_breakdown(uuid, date, date, text) to authenticated, service_role;
