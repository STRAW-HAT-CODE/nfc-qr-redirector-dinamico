# ADR-0003 · Redirección 302 sin caché

- Estado: Aceptado
- Fecha: 2026-10-05

## Contexto
Un 301 queda cacheado por navegadores y proxies, y el cambio de destino no se vería.

## Decisión
`302 Found` + `Cache-Control: no-store` en `/r/{slug}`.

## Alternativas descartadas
301; 307.

## Consecuencias
Cada escaneo llega al servidor (necesario para analytics); el redirector debe ser rápido.
