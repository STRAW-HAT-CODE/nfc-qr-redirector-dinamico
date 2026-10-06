# E2E (Playwright)

Criterio de DQR-07: crear enlace → descargar QR → escanear → ver la métrica → cambiar el destino.
`e2e/dynamic-qr.spec.ts` lo recorre contra el **Supabase de staging**, con API (`:8000`) y web (`:3000`) locales.

## Requisitos
- `apps/api/.env`: `SUPABASE_URL`, `SUPABASE_ANON_KEY`, `SUPABASE_SERVICE_ROLE_KEY`, `IP_HASH_SALT`.
- `apps/web/.env.local`: `NEXT_PUBLIC_SUPABASE_URL`, `NEXT_PUBLIC_SUPABASE_ANON_KEY`.
- Ambos están ignorados por git. `vercel env pull` **no** devuelve las variables marcadas *Sensitive*
  (llegan como `[SENSITIVE]`): esas hay que poner a mano. El test las trata como ausentes y se salta.
- La config fuerza `PUBLIC_REDIRECT_BASE_URL=http://localhost:8000`, `NEXT_PUBLIC_API_URL=http://localhost:8000`, `TRUSTED_PROXY_HOPS=0`.
- `uv` (API) y `pnpm exec playwright install chromium`.

## Ejecutar
```
pnpm test:e2e
```
Trazas, vídeo y capturas quedan en `test-results/` y el informe en `playwright-report/` (ambos ignorados).
Abrir una traza: `pnpm exec playwright show-trace test-results/<carpeta>/trace.zip`.

## Qué hace
1. Crea (Admin API, service role en memoria) `e2e+<timestamp>@example.com` confirmado.
2. UI: login → crea org → crea enlace → diseñador → descarga PNG → decodifica con jsQR y comprueba `http://localhost:8000/r/<slug>?c=q`.
3. `GET` de esa URL sin seguir redirect → 302 al destino.
4. `/links/[id]/stats` muestra 1 escaneo (hoy sale en vivo, sin esperar rollups).
5. Cambia el destino (confirmación) → mismo slug → 302 al nuevo; el historial lo muestra.
6. `afterAll` borra org y usuario aunque falle (si la org no cae en cascada se avisa en consola).
