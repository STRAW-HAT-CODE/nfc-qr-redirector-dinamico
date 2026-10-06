-- DQR-T022 · Seguimiento de seguridad (H2 + H3 de la revisión de PR #11)
-- Expand: solo reemplaza private.scan_clip; no toca la tabla ni record_scan.
--
-- H2: además de los controles C0/C1 ([[:cntrl:]]) quita caracteres de formato
--     Unicode: U+00AD (soft hyphen), U+200B..U+200F (zero-width, LRM/RLM),
--     U+2028..U+202E (separadores de línea/párrafo y overrides bidi, incl. RLO),
--     U+2060..U+206F (word joiner, isolates bidi…) y U+FEFF (BOM/ZWNBSP).
--     Normaliza secuencias de espacios (incl. NBSP U+00A0) a un único ' '
--     antes de btrim, para que un valor hecho solo de NBSP quede en NULL.
-- H3: recorta la entrada a p_max * 4 caracteres antes de aplicar las regex,
--     para no gastar CPU en entradas enormes (5 MB → 0,68 s antes).
--
-- Es el SQL del informe; los caracteres invisibles se escriben con escapes
-- \uXXXX (E'…') para que sean visibles en la revisión. La cadena resultante
-- es idéntica.
-- CREATE OR REPLACE conserva propietario y privilegios; se reafirman abajo.
create or replace function private.scan_clip(p_value text, p_max int)
returns text
language sql
immutable
set search_path = ''
as $$
  select nullif(
    left(btrim(regexp_replace(
      regexp_replace(left(p_value, p_max * 4),
        E'[[:cntrl:]­​-‏ -‮⁠-⁯﻿]', '', 'g'),
      E'[[:space:] ]+', ' ', 'g')), p_max),
    ''
  );
$$;

comment on function private.scan_clip(text, int) is
  'Saneado de cabeceras del cliente: quita controles y formato Unicode, '
  'normaliza espacios, recorta y corta a p_max; NULL si queda vacío (DQR-T022).';

alter function private.scan_clip(text, int) owner to postgres;
revoke execute on function private.scan_clip(text, int) from public, anon, authenticated;
grant execute on function private.scan_clip(text, int) to service_role;
