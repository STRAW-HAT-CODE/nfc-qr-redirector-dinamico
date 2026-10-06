-- =============================================================================
-- DQR-T053 · Planes y límites: public.plans + límites aplicados en la BD
-- Módulo DQR-09 · docs/03-modelo-datos.md (organizations.plan, limits) ·
-- ADR-0006 (los límites de plan se hacen cumplir también en la BD) ·
-- backlog de seguridad T013 H5 (orgs por usuario). T031 H2 (cuota de objetos
-- en el bucket logos) sigue abierto: max_logos cuenta diseños con logo, no
-- objetos de Storage (sec-T053 H1, en backlog).
--
-- Fase: EXPAND. Crea public.plans, añade la FK organizations.plan → plans.code
--   (antes valida que todas las orgs existentes tengan un plan del catálogo;
--   hoy solo existe 'free', el default) y triggers BEFORE INSERT que solo
--   rechazan filas nuevas por encima del límite. No toca filas existentes:
--   si una org baja de plan y ya supera el límite, conserva lo que tiene y
--   no puede crear más hasta quedar por debajo.
--
-- Decisiones:
--   * plans.limits: objeto con exactamente las claves max_links, max_members,
--     max_nfc_tags, max_logos y scans_retention_days; cada valor es un entero
--     ≥ 0 o null (= ilimitado). organizations.limits es un override parcial
--     por org: solo esas claves, mismo formato. Límite efectivo = la clave de
--     organizations.limits si está presente (aunque sea null) y, si no, la de
--     plans.limits (private.org_limit).
--   * scans_retention_days solo se guarda (lo consumirá la purga de
--     scan_events/rollups); aquí no se aplica.
--   * plans: lectura para authenticated (la UI muestra el catálogo); escritura
--     solo service_role. Sin anon.
--   * Qué cuenta contra el límite (todas las filas de la org):
--       max_links    → dynamic_links (incluidos pausados y archivados)
--       max_members  → memberships (incluido el owner)
--       max_nfc_tags → nfc_tags
--       max_logos    → qr_designs con logo_path no nulo (un diseño por enlace).
--                      Se comprueba al insertar con logo y al pasar logo_path
--                      de NULL a un valor (upsert de PostgREST incluido).
--   * Error: SQLSTATE P0001, hint 'plan_limit_reached', mensaje con el recurso
--     y el máximo. La API lo traduce a 409 plan_limit_reached (limits.py).
--   * Exentos: platform admin y cualquier rol que no sea authenticated/anon
--     (service_role, postgres: backend, migraciones, RPC SECURITY DEFINER como
--     create_organization), igual que organizations_guard.
--     Regla (sec-T053 H2): toda RPC SECURITY DEFINER futura que cree enlaces,
--     miembros, etiquetas o diseños en nombre de un usuario debe llamar a
--     private.enforce_plan_limit explícitamente o ser SECURITY INVOKER; si no,
--     se salta los límites.
--   * Carreras: el trigger es SECURITY INVOKER (current_user = rol real de la
--     petición) y delega en private.enforce_plan_limit (SECURITY DEFINER, para
--     contar todas las filas de la org sin RLS), que toma
--     SELECT … FOR NO KEY UPDATE sobre la fila de la org y luego cuenta. Dos
--     inserts concurrentes en la misma org se serializan; en READ COMMITTED la
--     cuenta posterior al lock ve la fila ya confirmada por el otro. FOR NO KEY
--     UPDATE no bloquea los FOR KEY SHARE de las FK. En REPEATABLE READ la
--     snapshot es antigua: se rechaza (0A000, hint plan_limit_isolation), como
--     en memberships_keep_last_owner. PostgREST usa READ COMMITTED.
--   * Si quien inserta no tiene en la org el rol que exige la política RLS de
--     INSERT (editor; admin para memberships), enforce_plan_limit no bloquea
--     ni cuenta: el error sigue siendo el 42501 de RLS y no se revela el uso
--     de otra org ni se permite bloquear su fila.
--   * create_organization: máximo 5 organizaciones como owner por usuario
--     (P0001, hint 'org_limit'); platform admin exento. Advisory lock por
--     usuario contra carreras. Solo limita la creación: ser promovido a owner
--     de una org ajena no está limitado.
--   * plan/limits de una org solo los cambia un platform admin o service_role:
--     ya lo impone private.organizations_guard (T013); los tests lo verifican.
--   * Auditoría de cambios de plan: depende de audit_log (T052).
-- =============================================================================

-- -----------------------------------------------------------------------------
-- Validación del formato de límites
-- -----------------------------------------------------------------------------
-- p_require_all: true para plans (todas las claves), false para el override.
create or replace function private.plan_limits_valid(p_limits jsonb, p_require_all boolean)
returns boolean
language sql
immutable
set search_path = ''
as $$
  select jsonb_typeof(p_limits) = 'object'
    and not exists (
      select 1
      from jsonb_each(p_limits) e
      where e.key not in ('max_links', 'max_members', 'max_nfc_tags', 'max_logos',
                          'scans_retention_days')
         or not (
           jsonb_typeof(e.value) = 'null'
           or (jsonb_typeof(e.value) = 'number'
               and e.value::text ~ '^[0-9]{1,9}$')
         )
    )
    and (
      not p_require_all
      or p_limits ?& array['max_links', 'max_members', 'max_nfc_tags', 'max_logos',
                           'scans_retention_days']
    );
$$;

revoke execute on function private.plan_limits_valid(jsonb, boolean) from public, anon;
grant execute on function private.plan_limits_valid(jsonb, boolean) to authenticated, service_role;

-- -----------------------------------------------------------------------------
-- Catálogo de planes
-- -----------------------------------------------------------------------------
create table public.plans (
  code        text primary key,
  name        text not null,
  limits      jsonb not null,
  created_at  timestamptz not null default now(),
  constraint plans_code_check
    check (code ~ '^[a-z][a-z0-9_]{0,31}$'),
  constraint plans_name_check
    check (char_length(btrim(name)) between 1 and 60),
  constraint plans_limits_check
    check (private.plan_limits_valid(limits, true))
);
comment on table public.plans is
  'Catálogo de planes (free/pro/business) y sus límites. Lectura authenticated; escritura service_role. DQR-09.';
comment on column public.plans.limits is
  'max_links, max_members, max_nfc_tags, max_logos, scans_retention_days: entero ≥ 0 o null (ilimitado).';

insert into public.plans (code, name, limits) values
  ('free', 'Free', jsonb_build_object(
     'max_links', 10, 'max_members', 3, 'max_nfc_tags', 10, 'max_logos', 5,
     'scans_retention_days', 30)),
  ('pro', 'Pro', jsonb_build_object(
     'max_links', 500, 'max_members', 10, 'max_nfc_tags', 500, 'max_logos', 100,
     'scans_retention_days', 365)),
  ('business', 'Business', jsonb_build_object(
     'max_links', 10000, 'max_members', 50, 'max_nfc_tags', 10000, 'max_logos', 1000,
     'scans_retention_days', 730))
on conflict (code) do nothing;

revoke all on public.plans from anon, authenticated;
grant select on public.plans to authenticated;
grant all on public.plans to service_role;

alter table public.plans enable row level security;

create policy plans_select
  on public.plans for select
  to authenticated
  using (true);
-- Sin políticas de escritura: solo service_role (bypassrls).

-- -----------------------------------------------------------------------------
-- organizations.plan → plans.code, organizations.limits con formato válido
-- -----------------------------------------------------------------------------
do $$
declare
  v_bad text;
begin
  select string_agg(distinct o.plan, ', ') into v_bad
  from public.organizations o
  where not exists (select 1 from public.plans p where p.code = o.plan);
  if v_bad is not null then
    raise exception 'T053: organizaciones con plan fuera del catálogo: %', v_bad;
  end if;

  select string_agg(o.slug, ', ') into v_bad
  from public.organizations o
  where not private.plan_limits_valid(o.limits, false);
  if v_bad is not null then
    raise exception 'T053: organizaciones con limits no válidos: %', v_bad;
  end if;
end;
$$;

alter table public.organizations
  add constraint organizations_plan_fkey
    foreign key (plan) references public.plans (code)
    on update cascade on delete restrict;

alter table public.organizations
  add constraint organizations_limits_format_check
    check (private.plan_limits_valid(limits, false));

create index organizations_plan_idx on public.organizations (plan);

comment on column public.organizations.limits is
  'Override de límites por org (subconjunto de las claves de plans.limits; null = ilimitado). Solo platform admin / service_role.';

-- -----------------------------------------------------------------------------
-- Límite efectivo
-- -----------------------------------------------------------------------------
-- NULL = ilimitado (org inexistente también devuelve NULL).
create or replace function private.org_limit(p_org_id uuid, p_key text)
returns bigint
language sql
stable
security definer
set search_path = ''
as $$
  select case
           when o.limits ? p_key then (o.limits ->> p_key)::bigint
           else (p.limits ->> p_key)::bigint
         end
  from public.organizations o
  join public.plans p on p.code = o.plan
  where o.id = p_org_id;
$$;

revoke execute on function private.org_limit(uuid, text) from public, anon;
grant execute on function private.org_limit(uuid, text) to authenticated, service_role;

-- -----------------------------------------------------------------------------
-- Comprobación de límites (lock de la org + cuenta)
-- -----------------------------------------------------------------------------
-- p_resource: links | members | nfc_tags | logos.
-- p_exclude_link: solo para logos; el diseño del propio enlace no cuenta (el
-- upsert reemplaza esa fila).
create or replace function private.enforce_plan_limit(
  p_org_id uuid,
  p_resource text,
  p_exclude_link uuid default null
)
returns void
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_key   text;
  v_label text;
  v_role  public.org_role;
  v_limit bigint;
  v_count bigint;
begin
  -- v_role: rol mínimo que exige la política RLS de INSERT del recurso.
  case p_resource
    when 'links'    then v_key := 'max_links';    v_label := 'enlaces';       v_role := 'editor';
    when 'members'  then v_key := 'max_members';  v_label := 'miembros';      v_role := 'admin';
    when 'nfc_tags' then v_key := 'max_nfc_tags'; v_label := 'etiquetas NFC'; v_role := 'editor';
    when 'logos'    then v_key := 'max_logos';    v_label := 'logos';         v_role := 'editor';
    else raise exception 'enforce_plan_limit: recurso desconocido %', p_resource;
  end case;

  -- Sin el rol que exige RLS: la política rechazará el INSERT (42501). No se
  -- bloquea ni se cuenta nada (no revela el uso de otra org ni la bloquea).
  if not private.has_org_role(p_org_id, v_role) then
    return;
  end if;

  -- Serializa altas de la misma org. Org inexistente: lo resolverá la FK.
  perform 1 from public.organizations o where o.id = p_org_id for no key update;
  if not found then
    return;
  end if;

  v_limit := private.org_limit(p_org_id, v_key);
  if v_limit is null then
    return;
  end if;

  if current_setting('transaction_isolation') = 'repeatable read' then
    raise exception 'Crear recursos con límite de plan requiere READ COMMITTED o SERIALIZABLE'
      using errcode = '0A000', hint = 'plan_limit_isolation';
  end if;

  case p_resource
    when 'links' then
      select count(*) into v_count from public.dynamic_links t where t.org_id = p_org_id;
    when 'members' then
      select count(*) into v_count from public.memberships t where t.org_id = p_org_id;
    when 'nfc_tags' then
      select count(*) into v_count from public.nfc_tags t where t.org_id = p_org_id;
    when 'logos' then
      select count(*) into v_count
      from public.qr_designs t
      where t.org_id = p_org_id
        and t.logo_path is not null
        and t.link_id is distinct from p_exclude_link;
  end case;

  if v_count >= v_limit then
    raise exception 'Has alcanzado el límite de tu plan: máximo % %', v_limit, v_label
      using errcode = 'P0001',
            hint = 'plan_limit_reached',
            detail = format('resource=%s limit=%s', p_resource, v_limit);
  end if;
end;
$$;

revoke execute on function private.enforce_plan_limit(uuid, text, uuid) from public, anon;
-- authenticated lo necesita: lo invocan triggers SECURITY INVOKER. private no
-- está expuesto por PostgREST.
grant execute on function private.enforce_plan_limit(uuid, text, uuid) to authenticated, service_role;

-- -----------------------------------------------------------------------------
-- Triggers BEFORE INSERT (SECURITY INVOKER: current_user = rol de la petición)
-- -----------------------------------------------------------------------------
create or replace function private.plan_limit_guard()
returns trigger
language plpgsql
security invoker
set search_path = ''
as $$
begin
  -- Exentos: service_role, postgres y RPC SECURITY DEFINER; platform admin.
  if current_user not in ('authenticated', 'anon') or private.is_platform_admin() then
    return new;
  end if;

  if tg_table_name = 'qr_designs' then
    if new.logo_path is null
       or (tg_op = 'UPDATE' and old.logo_path is not null)
    then
      return new;
    end if;
    perform private.enforce_plan_limit(new.org_id, 'logos', new.link_id);
  else
    perform private.enforce_plan_limit(new.org_id, tg_argv[0]);
  end if;

  return new;
end;
$$;

revoke execute on function private.plan_limit_guard() from public, anon, authenticated;

create trigger dynamic_links_plan_limit
  before insert on public.dynamic_links
  for each row execute function private.plan_limit_guard('links');

create trigger memberships_plan_limit
  before insert on public.memberships
  for each row execute function private.plan_limit_guard('members');

create trigger nfc_tags_plan_limit
  before insert on public.nfc_tags
  for each row execute function private.plan_limit_guard('nfc_tags');

-- INSERT con logo y UPDATE que añade logo (upsert de PostgREST: BEFORE INSERT
-- y, si hay conflicto, BEFORE UPDATE).
create trigger qr_designs_plan_limit
  before insert or update of logo_path on public.qr_designs
  for each row execute function private.plan_limit_guard('logos');

-- -----------------------------------------------------------------------------
-- create_organization: máximo 5 organizaciones como owner (security T013 H5)
-- -----------------------------------------------------------------------------
create or replace function public.create_organization(p_name text, p_slug text)
returns public.organizations
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_uid uuid := (select auth.uid());
  v_max constant int := 5;
  v_org public.organizations;
begin
  if v_uid is null then
    raise exception 'Autenticación requerida' using errcode = '42501';
  end if;

  if not private.is_platform_admin() then
    -- Serializa las altas del mismo usuario.
    perform pg_advisory_xact_lock(hashtextextended('dqr:create_organization:' || v_uid::text, 0));

    if (select count(*)
        from public.memberships m
        where m.user_id = v_uid and m.role = 'owner') >= v_max
    then
      raise exception 'Has alcanzado el máximo de % organizaciones propias', v_max
        using errcode = 'P0001', hint = 'org_limit';
    end if;
  end if;

  insert into public.organizations (name, slug)
  values (btrim(p_name), lower(btrim(p_slug)))
  returning * into v_org;

  insert into public.memberships (org_id, user_id, role)
  values (v_org.id, v_uid, 'owner');

  return v_org;
end;
$$;

revoke execute on function public.create_organization(text, text) from public, anon;
grant execute on function public.create_organization(text, text) to authenticated;
