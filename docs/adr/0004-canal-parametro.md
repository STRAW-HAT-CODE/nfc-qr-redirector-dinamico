# ADR-0004 · Canal por parámetro

- Estado: Aceptado
- Fecha: 2026-10-05

## Contexto
Queremos distinguir escaneos por QR y por NFC del mismo enlace.

## Decisión
Mismo slug con `?c=q` (QR), `?c=n` (NFC) y `&t={tag}` para la etiqueta; sin parámetro = `direct`.

## Alternativas descartadas
Un slug distinto por canal.

## Consecuencias
Un solo enlace que gestionar; el parámetro no afecta el destino.
