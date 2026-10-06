# Plantillas imprimibles y Canva (DQR-T033 · ADR-0005)

Tres piezas listas para imprimir o editar en Canva. Todas llevan el QR del diseño del enlace
(colores, marco, estilo de módulos y logo), un **título** (por defecto el nombre del enlace),
una **llamada a la acción** y una zona segura.

| Plantilla | `template=` | Medida (mm) | Detalle |
|---|---|---|---|
| Sticker | `sticker` | 50×50 de corte, lienzo 56×56 | 3 mm de sangrado por lado; zona segura 3 mm dentro del corte |
| Display de mostrador | `display` | A6 105×148 | zona segura 8 mm |
| Póster | `poster` | A4 210×297 | zona segura 15 mm |

Llamada a la acción: «Escanéame»; «Acerca tu móvil» si el enlace tiene tags NFC.
El QR codifica siempre `PUBLIC_REDIRECT_BASE_URL/r/{slug}?c=q` (los tags NFC llevan su propia URL `?c=n&t=…`).

## Descargar
```
GET /v1/links/{id}/qr.svg|pdf|png?template=sticker|display|poster[&title=Mesa 7]
```
- `svg`: vectorial, `viewBox` en mm, texto como `<text>` editable. **Mejor formato para Canva.**
- `pdf`: vectorial (texto Helvetica estándar); el sticker incluye TrimBox/BleedBox para imprenta.
- `png`: 300 dpi con las medidas reales (el parámetro `size` se ignora con plantilla).
- `title`: 1–80 caracteres sin controles (si no se envía, nombre del enlace; se ajusta/trunca).
- `template` o `title` inválidos → 422.

## Importar en Canva
1. En Canva: **Crear diseño → Tamaño personalizado** con las medidas de la tabla (mm).
   Para el sticker usa 56×56 mm (incluye sangrado).
2. **Subir archivos** y arrastra el `.svg` descargado; ajústalo al lienzo (mismo tamaño, no lo estires).
3. El título y la llamada a la acción son texto editable. Cambia fuente, color y texto libremente.
4. Descarga como **PDF para impresión** (con sangrado en el sticker) o PNG.

## Editar sin romper el QR
- **No estires ni deformes** el QR: escálalo solo con la proporción bloqueada (esquinas).
- **Mantén la zona de silencio**: deja al menos 4 módulos (~4 × el lado de un cuadradito) de fondo
  liso alrededor; no pongas texto, fotos ni formas pegadas al QR.
- **Mantén el contraste**: módulos oscuros sobre fondo claro (≥ 4.5:1). No inviertas los colores ni
  uses degradados o fotos detrás del QR.
- No cambies colores, no recortes ni apliques efectos (sombras, transparencias, filtros) al QR.
- Tamaño mínimo recomendado impreso: 2 cm de lado para el bloque del QR.
- **Prueba siempre**: escanea el resultado con 2 móviles distintos antes de imprimir en cantidad.
- Si cambias el diseño del QR (colores, logo, marco), vuelve a descargar la plantilla; no edites a mano.

## Reseñas de Google
Diseño rápido y plantilla para pedir reseñas de un local en Google.

- **Preset**: `PUT /v1/links/{id}/design` con `"logo_preset": "google"` (lista blanca; otro valor → 422) pone la «G» de Google al centro del QR. Fuerza ECC **H**, el logo sale de un asset incluido en el repo (`apps/api/app/assets/logos/`), no de Storage, y **no cuenta en la cuota de logos**. Si el diseño tiene también un logo propio (`logo_path`), **gana el preset** (el logo propio se conserva y vuelve al quitar el preset). Valores recomendados: `fg #000000`, `bg #FFFFFF`, `frame none`, `module_style square`.
- **Plantilla**: `GET /v1/links/{id}/qr.svg|pdf|png?template=google_review[&title=…]`: tarjeta A6 (105×148 mm) con el texto «¿Te gustó? Déjanos tu reseña en Google» (editable con `title`), 5 estrellas, el QR con la G (siempre, aunque el diseño no tenga el preset) y el nombre del enlace como nombre del local.
- **Uso de marca**: úsalo **solo para enlazar al perfil de Google Business (reseñas) del propio negocio**, según las [guías de marca de Google](https://about.google/brand-resource-center/). No lo uses para otros destinos, no modifiques los colores de la «G» ni insinúes que Google respalda el servicio.
- El QR sigue codificando `PUBLIC_REDIRECT_BASE_URL/r/{slug}?c=q`; apunta el enlace a la URL de reseñas de tu ficha de Google.
