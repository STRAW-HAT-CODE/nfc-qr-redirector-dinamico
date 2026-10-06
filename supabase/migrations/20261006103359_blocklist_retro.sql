-- =============================================================================
-- DQR-T057-N1 · Blocklist retroactiva (sec-T057 N1 · T018-H8)
-- Módulo DQR-08/09 · ADR-0006 · depende de 20261006095834_platform_admin.sql
--
-- Fase: EXPAND (cambia el tipo de retorno de resolve_link añadiendo una
-- columna al final y crea una RPC nueva; no toca tablas ni datos).
--
-- Problema: bloquear un dominio solo impedía crear o editar enlaces hacia él;
-- los enlaces ya existentes seguían redirigiendo (resolve_link no consultaba
-- la blocklist).
--
-- Decisiones:
--   * resolve_link devuelve además destination_blocked =
--     private.url_is_blocked(destination_url). Contrato del redirector:
--     destination_blocked = true se trata igual que suspended_at not null
--     (página "no disponible", sin fallback).
--   * Fallback bloqueado: resolve_link devuelve fallback_url = NULL si su
--     dominio está bloqueado. Así el redirector, sin cambios, nunca envía a un
--     dominio bloqueado por la vía del fallback (enlace pausado/caducado →
--     "no disponible"). El valor guardado no cambia.
--   * resolve_link cambia su tipo de retorno: drop + create con los mismos
--     grants (solo service_role).
--   * public.admin_list_blocked_links(p_limit): enlaces (de cualquier org)
--     cuyo destino o fallback cae en la blocklist, para que la consola los
--     revise/suspenda. Solo platform admin (42501); SECURITY DEFINER,
--     search_path ''; EXECUTE solo authenticated. limit acotado a 1..1000
--     (NULL → 100). Orden: created_at desc, id. Recorre dynamic_links
--     completo (url_is_blocked por fila): aceptable para una consulta de
--     consola; si crece, materializar el host del destino e indexarlo.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- resolve_link + destination_blocked
-- -----------------------------------------------------------------------------
drop function public.resolve_link(text);

create function public.resolve_link(p_slug text)
returns table (
  id                   uuid,
  org_id               uuid,
  destination_url      text,
  fallback_url         text,
  status               public.link_status,
  starts_at            timestamptz,
  expires_at           timestamptz,
  org_status           public.org_status,
  suspended_at         timestamptz,
  destination_blocked  boolean
)
language sql
stable
security definer
set search_path = ''
as $$
  select l.id, l.org_id, l.destination_url,
         case when l.fallback_url is not null and private.url_is_blocked(l.fallback_url)
              then null else l.fallback_url end,
         l.status, l.starts_at, l.expires_at, o.status, l.suspended_at,
         private.url_is_blocked(l.destination_url)
  from public.dynamic_links l
  join public.organizations o on o.id = l.org_id
  where l.slug = p_slug;
$$;

comment on function public.resolve_link(text) is
  'Redirector (service_role). suspended_at not null o destination_blocked = no disponible, sin fallback. fallback_url llega NULL si su dominio está bloqueado.';

revoke execute on function public.resolve_link(text) from public, anon, authenticated;
grant execute on function public.resolve_link(text) to service_role;

-- -----------------------------------------------------------------------------
-- Consola: enlaces afectados por la blocklist
-- -----------------------------------------------------------------------------
create or replace function public.admin_list_blocked_links(p_limit int default 100)
returns table (
  id                   uuid,
  org_id               uuid,
  org_name             text,
  slug                 text,
  name                 text,
  destination_url      text,
  fallback_url         text,
  status               public.link_status,
  suspended_at         timestamptz,
  destination_blocked  boolean,
  fallback_blocked     boolean,
  created_at           timestamptz
)
language plpgsql
stable
security definer
set search_path = ''
as $$
#variable_conflict use_column
declare
  v_limit int := least(greatest(coalesce(p_limit, 100), 1), 1000);
begin
  perform private.assert_platform_admin();

  return query
  select x.id, x.org_id, x.org_name, x.slug, x.name, x.destination_url, x.fallback_url,
         x.status, x.suspended_at, x.destination_blocked, x.fallback_blocked, x.created_at
  from (
    select l.id, l.org_id, o.name as org_name, l.slug, l.name, l.destination_url,
           l.fallback_url, l.status, l.suspended_at, l.created_at,
           private.url_is_blocked(l.destination_url) as destination_blocked,
           coalesce(l.fallback_url is not null and private.url_is_blocked(l.fallback_url), false)
             as fallback_blocked
    from public.dynamic_links l
    join public.organizations o on o.id = l.org_id
  ) x
  where x.destination_blocked or x.fallback_blocked
  order by x.created_at desc, x.id
  limit v_limit;
end;
$$;

comment on function public.admin_list_blocked_links(int) is
  'Consola Monky: enlaces cuyo destino o fallback está en la blocklist. Solo platform admin. DQR-T057-N1.';

revoke execute on function public.admin_list_blocked_links(int) from public, anon, service_role;
grant execute on function public.admin_list_blocked_links(int) to authenticated;
