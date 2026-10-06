-- =============================================================================
-- DQR-T031 · Diseños de QR: qr_designs + bucket privado `logos`
-- Módulo DQR-04 · docs/03-modelo-datos.md (qr_designs) · docs/06-seguridad.md
--
-- Fase: EXPAND (solo añade objetos; depende de 20261006013540_links.sql y de
--   la clave unique (id, org_id) de dynamic_links de 20261006022927_scan_events.sql).
--
-- Decisiones:
--   * Un diseño por enlace: link_id es la PK. Coherencia de org con la FK
--     compuesta (link_id, org_id) → dynamic_links (id, org_id) on delete
--     cascade, como en scan_events: un diseño no puede llevar un org_id
--     distinto al de su enlace, para ningún rol. link_id y org_id son
--     inmutables (trigger, todos los roles).
--   * Colores fg/bg en '#RRGGBB' (hex, mayúsculas o minúsculas). Sin alfa.
--   * frame ∈ none/simple/rounded/label y ecc_level ∈ L/M/Q/H como text con
--     CHECK (catálogo pequeño y fácil de ampliar sin ALTER TYPE).
--   * Con logo, ECC H obligatorio (criterio de DQR-04): CHECK
--     logo_path is null or ecc_level = 'H'.
--   * style: objeto JSON de ≤ 4096 bytes (texto). Lo interpreta qr_render.
--   * logo_path: clave del objeto dentro del bucket `logos` (sin el nombre del
--     bucket). Debe empezar por '{org_id}/' de la propia fila, así un editor no
--     puede apuntar al logo de otra organización (la API renderiza el logo).
--     El formato lo valida private.logo_path_org_id(), la misma función que
--     usan las políticas de storage.objects.
--   * Permisos (matriz de docs/03): viewer lee; editor+ crea y actualiza
--     (upsert); admin+ borra. Platform admin puede todo.
--   * Grants por columna. UPDATE incluye link_id y org_id solo porque el
--     upsert de PostgREST (on_conflict=link_id) genera SET para todas las
--     columnas del payload; el trigger impide cambiarlas de verdad.
--     updated_at no es escribible (lo fija el trigger).
--   * Bucket `logos`: privado, 1 MiB, PNG/JPEG/WebP. SVG NO se admite:
--       - un SVG puede llevar <script>/handlers on*/<foreignObject>; servido
--         desde Storage con image/svg+xml (URL firmada abierta en el
--         navegador) es XSS almacenado en el dominio del proyecto;
--       - para incrustarlo en el QR habría que rasterizarlo en la API
--         (cairosvg o similar): superficie de XXE/SSRF (entidades externas,
--         href a file:// o http://) y "billion laughs";
--       - Pillow no lee SVG; PNG/WebP con transparencia cubren el caso de uso.
--     Si en el futuro se quiere SVG, añadirlo exige sanear en la API y
--     servir con Content-Disposition: attachment (nuevo ADR).
--     allowed_mime_types valida el Content-Type declarado, no el contenido:
--     la API debe comprobar los magic bytes (pendiente qr-nfc).
--   * Extensión obligatoria .png/.jpg/.jpeg/.webp en logo_path y en los
--     nombres de objeto del bucket (security H1). Sin cuota de logos por org:
--     queda en backlog para T053 (límites de plan, security H2).
--   * storage.objects (bucket logos): la ruta debe empezar por '{org_id}/';
--     viewer+ de esa org lee; editor+ sube, reemplaza (upsert = INSERT +
--     SELECT + UPDATE) y borra. Platform admin puede todo. anon nada.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- Helper: org de una ruta de logo
-- -----------------------------------------------------------------------------
-- Devuelve el org_id de una clave '{org_id}/{segmento}[/{segmento}…]' o NULL si
-- el formato no es válido. org_id: uuid canónico en minúsculas (= uuid::text).
-- Segmentos: [A-Za-z0-9_-] seguido de [A-Za-z0-9._-], 1..128 caracteres; no
-- pueden empezar por '.', así que no hay '.', '..' ni ocultos. Máx. 512.
-- El último segmento debe acabar en .png, .jpg, .jpeg o .webp (sin distinguir
-- mayúsculas; security H1): defensa en profundidad frente a CDN/herramientas
-- que deducen el tipo por la extensión (.html, .svg). SVG no se admite.
-- Nunca lanza errores (se usa en CHECK y en políticas RLS).
create or replace function private.logo_path_org_id(p_path text)
returns uuid
language sql
immutable
set search_path = ''
as $$
  select case
    when char_length(p_path) <= 512
     and p_path ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}(/[A-Za-z0-9_-][A-Za-z0-9._-]{0,127})+$'
     and p_path ~* '\.(png|jpe?g|webp)$'
    then left(p_path, 36)::uuid
  end;
$$;

-- Se evalúa en CHECK y en políticas con el rol de quien escribe/lee.
revoke execute on function private.logo_path_org_id(text) from public, anon;
grant execute on function private.logo_path_org_id(text) to authenticated, service_role;

-- -----------------------------------------------------------------------------
-- Tabla
-- -----------------------------------------------------------------------------
create table public.qr_designs (
  link_id     uuid primary key,
  org_id      uuid not null,
  fg          text not null default '#000000',
  bg          text not null default '#FFFFFF',
  logo_path   text,
  frame       text not null default 'none',
  ecc_level   text not null default 'M',
  style       jsonb not null default '{}'::jsonb,
  updated_at  timestamptz not null default now(),
  constraint qr_designs_link_org_fkey
    foreign key (link_id, org_id)
    references public.dynamic_links (id, org_id)
    on delete cascade,
  constraint qr_designs_fg_check
    check (fg ~ '^#[0-9A-Fa-f]{6}$'),
  constraint qr_designs_bg_check
    check (bg ~ '^#[0-9A-Fa-f]{6}$'),
  constraint qr_designs_frame_check
    check (frame in ('none', 'simple', 'rounded', 'label')),
  constraint qr_designs_ecc_level_check
    check (ecc_level in ('L', 'M', 'Q', 'H')),
  -- Con logo se usa ECC H (DQR-04).
  constraint qr_designs_logo_ecc_check
    check (logo_path is null or ecc_level = 'H'),
  -- Clave del bucket logos bajo la carpeta de la propia org. IS NOT DISTINCT
  -- FROM: una ruta inválida (función → NULL) debe fallar, no pasar como NULL.
  constraint qr_designs_logo_path_check
    check (logo_path is null or private.logo_path_org_id(logo_path) is not distinct from org_id),
  constraint qr_designs_style_check
    check (jsonb_typeof(style) = 'object' and octet_length(style::text) <= 4096)
);
comment on table public.qr_designs is
  'Diseño del QR de un enlace (1:1). Logo en el bucket privado logos/{org_id}/. DQR-04.';
comment on column public.qr_designs.org_id is
  'Coherente con el enlace por la FK compuesta (link_id, org_id) → dynamic_links (id, org_id).';
comment on column public.qr_designs.logo_path is
  'Clave en el bucket logos (sin el nombre del bucket): {org_id}/… de la propia org. Exige ecc_level = H.';
comment on column public.qr_designs.style is
  'Opciones extra de render (objeto JSON, ≤ 4096 bytes). Las interpreta qr_render.';

-- link_id: índice de la PK (cubre la FK compuesta, columna inicial link_id).
-- org_id: RLS y listados por organización.
create index qr_designs_org_id_idx on public.qr_designs (org_id);

-- -----------------------------------------------------------------------------
-- Trigger: link_id/org_id inmutables y updated_at
-- -----------------------------------------------------------------------------
-- SECURITY INVOKER: no necesita privilegios extra. Aplica a todos los roles.
create or replace function private.qr_designs_guard()
returns trigger
language plpgsql
security invoker
set search_path = ''
as $$
begin
  if new.link_id is distinct from old.link_id
     or new.org_id is distinct from old.org_id
  then
    raise exception 'qr_designs: link_id y org_id son inmutables'
      using errcode = '42501', hint = 'immutable_column';
  end if;

  new.updated_at := now();
  return new;
end;
$$;

create trigger qr_designs_guard
  before update on public.qr_designs
  for each row execute function private.qr_designs_guard();

revoke execute on function private.qr_designs_guard() from public, anon, authenticated;

-- -----------------------------------------------------------------------------
-- Privilegios de tabla (explícitos; RLS filtra filas)
-- -----------------------------------------------------------------------------
revoke all on public.qr_designs from anon, authenticated;

grant select, delete on public.qr_designs to authenticated;
-- updated_at no falsificable (default now() / trigger).
grant insert (link_id, org_id, fg, bg, logo_path, frame, ecc_level, style)
  on public.qr_designs to authenticated;
-- link_id/org_id: solo para el upsert de PostgREST (el trigger impide cambiarlos).
grant update (link_id, org_id, fg, bg, logo_path, frame, ecc_level, style)
  on public.qr_designs to authenticated;

grant all on public.qr_designs to service_role;

-- -----------------------------------------------------------------------------
-- RLS
-- -----------------------------------------------------------------------------
alter table public.qr_designs enable row level security;

create policy qr_designs_select
  on public.qr_designs for select
  to authenticated
  using (
    private.is_org_member(org_id)
    or (select private.is_platform_admin())
  );

create policy qr_designs_insert
  on public.qr_designs for insert
  to authenticated
  with check (
    private.has_org_role(org_id, 'editor')
    or (select private.is_platform_admin())
  );

create policy qr_designs_update
  on public.qr_designs for update
  to authenticated
  using (
    private.has_org_role(org_id, 'editor')
    or (select private.is_platform_admin())
  )
  with check (
    private.has_org_role(org_id, 'editor')
    or (select private.is_platform_admin())
  );

create policy qr_designs_delete
  on public.qr_designs for delete
  to authenticated
  using (
    private.has_org_role(org_id, 'admin')
    or (select private.is_platform_admin())
  );

-- -----------------------------------------------------------------------------
-- Storage: bucket privado `logos`
-- -----------------------------------------------------------------------------
-- Idempotente: si el bucket ya existe se reafirma su configuración.
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values (
  'logos',
  'logos',
  false,
  1048576,  -- 1 MiB
  array['image/png', 'image/jpeg', 'image/webp']
)
on conflict (id) do update
  set public             = excluded.public,
      file_size_limit    = excluded.file_size_limit,
      allowed_mime_types = excluded.allowed_mime_types;

-- Políticas en storage.objects (solo bucket logos; ruta '{org_id}/…').
create policy logos_select
  on storage.objects for select
  to authenticated
  using (
    bucket_id = 'logos'
    and (
      private.is_org_member(private.logo_path_org_id(name))
      or (select private.is_platform_admin())
    )
  );

create policy logos_insert
  on storage.objects for insert
  to authenticated
  with check (
    bucket_id = 'logos'
    and (
      private.has_org_role(private.logo_path_org_id(name), 'editor')
      or (
        (select private.is_platform_admin())
        and private.logo_path_org_id(name) is not null
      )
    )
  );

create policy logos_update
  on storage.objects for update
  to authenticated
  using (
    bucket_id = 'logos'
    and (
      private.has_org_role(private.logo_path_org_id(name), 'editor')
      or (select private.is_platform_admin())
    )
  )
  with check (
    bucket_id = 'logos'
    and (
      private.has_org_role(private.logo_path_org_id(name), 'editor')
      or (
        (select private.is_platform_admin())
        and private.logo_path_org_id(name) is not null
      )
    )
  );

create policy logos_delete
  on storage.objects for delete
  to authenticated
  using (
    bucket_id = 'logos'
    and (
      private.has_org_role(private.logo_path_org_id(name), 'editor')
      or (select private.is_platform_admin())
    )
  );
