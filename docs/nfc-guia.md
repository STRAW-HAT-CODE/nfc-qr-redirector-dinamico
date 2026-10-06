# Guía de grabado NFC

Cómo grabar una etiqueta (sticker, tarjeta o llavero) para que abra tu enlace dinámico y cuente el escaneo como canal `nfc`. No necesitas programar: basta la app gratuita **NFC Tools**.

## 1. Qué chip comprar

| Chip | Memoria total | Cuándo usarlo |
|---|---|---|
| **NTAG213** | 144 bytes | Lo recomendado: barato y suficiente. La URL NDEF debe ocupar **≤ 137 bytes**. |
| NTAG215 | 504 bytes | Si tu dominio es largo o quieres margen. |
| NTAG216 | 888 bytes | Solo si necesitas más espacio; rara vez hace falta. |

- Compra chips **NTAG** (compatibles con iPhone y Android). Evita MIFARE Classic: los iPhone no lo leen.
- Para pegar sobre **metal**, compra etiquetas "anti-metal" (con ferrita); las normales no funcionan.
- Un dominio de ~25 caracteres cabe de sobra en un NTAG213 (la URL ronda los 70 bytes).

## 2. Obtén la URL de la etiqueta

1. Crea la etiqueta en el panel (o con `POST /v1/links/{id}/nfc-tags`) indicando nombre (`label`), ubicación (`location`) y, opcionalmente, el UID del chip.
2. Copia el campo **`ndef_url`**. Tiene esta forma:
   `https://tu-dominio/r/{slug}?c=n&t={id-de-la-etiqueta}`
3. Mira `ndef_bytes` y `ndef_fits`: si `ndef_fits` es `false` la URL no cabe en un NTAG213 (lee `ndef_warning`).

> Cada chip debe llevar **su propia** `ndef_url`: el parámetro `t` es lo que permite saber en qué ubicación se escaneó. No reutilices la URL de una etiqueta en otro chip.

El UID del chip se ve en NFC Tools, pestaña **Leer** (campo "Serial number", p. ej. `04:A2:5B:1C:2D:3E:4F`). Es opcional; sirve para evitar registrar el mismo chip dos veces (el UID es único por organización).

## 3. Grabar con NFC Tools

### Android
1. Instala **NFC Tools** desde Google Play y activa NFC en Ajustes.
2. Abre la app → pestaña **Escribir** → **Añadir un registro** → **URL / URI**.
3. Pega la `ndef_url` (elige el prefijo `https://` o deja que la app lo detecte) y confirma con **OK**.
4. Pulsa **Escribir / 1 registro** y acerca el chip a la parte trasera del teléfono (cerca de la cámara) hasta ver "Escritura completada".

### iPhone (iOS)
1. Instala **NFC Tools** desde la App Store (iPhone 7 o posterior, iOS 13+).
2. Abre la app → **Escribir** → **Añadir un registro** → **URL / URI** → pega la `ndef_url` → **OK**.
3. Pulsa **Escribir / 1 registro**; aparece una hoja del sistema: acerca el chip a la parte superior del iPhone y espera la confirmación.

Si falla, mantén el chip quieto 2-3 segundos, quita fundas gruesas y reintenta.

## 4. Probar

1. Con el teléfono desbloqueado, acerca el chip: debe mostrarse un aviso para abrir el enlace (iPhone: banner; Android: notificación o apertura directa).
2. Comprueba que llegas al destino correcto.
3. En el panel, el escaneo aparece con canal **nfc** y el nombre/ubicación de la etiqueta (puede tardar unos segundos).
4. Prueba con un teléfono distinto (iOS y Android) antes de producir muchas unidades.

## 5. Bloquear la escritura (opcional)

En NFC Tools → **Otros** → **Bloquear etiqueta** el chip pasa a **solo lectura**, y evita que alguien con un móvil reescriba la etiqueta y la desvíe a otro sitio.

> ⚠️ **Es irreversible.** Un chip bloqueado no se puede volver a escribir ni desbloquear. Bloquea solo cuando la `ndef_url` esté verificada y confirmada. Como el destino lo cambias desde el panel (la URL del chip no cambia), normalmente no necesitas reescribirlo nunca: bloquear es seguro para los chips que ya estén en producción.

## 6. Resolución de problemas

| Síntoma | Causa probable |
|---|---|
| "No hay suficiente espacio" | La URL supera la memoria del chip → usa NTAG215/216 o un dominio más corto. |
| El iPhone no lo detecta | Chip no NTAG (p. ej. MIFARE Classic) o está sobre metal. |
| Se abre pero cuenta como `direct` | Se grabó la URL sin `?c=n&t=…`; vuelve a copiar la `ndef_url` completa. |
| Cuenta como `nfc` sin ubicación | La etiqueta se borró en el panel (los escaneos se conservan sin etiqueta) o `t` está mal copiado. |
