# 1 · Producto y requisitos

## Problema
Un QR o una etiqueta NFC impresos quedan atados a una URL. Si la URL cambia hay que reimprimir, y nadie sabe cuántas personas escanean, cuándo ni desde dónde.

## Solución
Cada código apunta a un enlace corto propio `https://<dominio>/r/{slug}`. El destino real se edita en el dashboard sin tocar lo impreso, y cada escaneo se registra.

## Actores y roles
| Actor | Puede |
|---|---|
| Platform admin (Monky) | Gestionar todos los clientes, planes; suspender enlaces/organizaciones |
| Owner | Todo en su organización, incluido borrarla |
| Admin | Enlaces, diseños, NFC y miembros |
| Editor | Crear y editar enlaces, diseños y NFC |
| Viewer | Ver enlaces y métricas |
| Visitante | Escanea; anónimo |

## Requisitos funcionales (MVP)
- **RF1** Crear enlace dinámico: nombre, destino, fallback y vigencia opcional.
- **RF2** Cambiar destino sin cambiar el slug; historial de destinos.
- **RF3** Pausar / reactivar / archivar.
- **RF4** Redirección pública `/r/{slug}` con canal `?c=q` (QR), `?c=n` (NFC); sin parámetro = `direct`.
- **RF5** Generar QR con diseño (colores, logo, marco, ECC) y descargar PNG/SVG/PDF.
- **RF6** Plantillas imprimibles y flujo para terminar el diseño en Canva.
- **RF7** Etiquetas NFC por enlace (ubicación) con su URL NDEF.
- **RF8** Analytics: escaneos por día, canal, país, dispositivo; totales y únicos.
- **RF9** Organizaciones, miembros y roles.
- **RF10** Consola de plataforma para Monky.

## Requisitos no funcionales
- Redirección p95 < 150 ms; registrar el escaneo nunca bloquea ni rompe la redirección.
- Disponibilidad 99,9 % del redirector.
- Aislamiento total entre clientes (RLS en todas las tablas).
- Privacidad: IP solo hasheada con sal; sin cookies en `/r`.
- Lo impreso nunca se rompe: slug inmutable, fallback si pausado/vencido.
- Dashboard accesible y usable en móvil.

## Fuera del MVP
Dominios personalizados, reglas por geo/dispositivo/horario, A/B, carga masiva CSV, API keys, webhooks, facturación.
