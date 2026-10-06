# nfc-qr-redirector-dinamico

API de redirección dinámica para tarjetas NFC y códigos QR — **Dynamic QR**, plataforma SaaS multi-tenant de Monky.

- Especificación: [`docs/00-hub.md`](docs/00-hub.md)
- Flujo y reglas para agentes: [`AGENTS.md`](AGENTS.md)
- Tablero: [`BOARD.md`](BOARD.md) (espejo de Notion)

Stack: FastAPI (Python) · Next.js · Supabase · Vercel.

## Arranque local
Requisitos: Python 3.12 + [uv](https://docs.astral.sh/uv/), Node 20+ con pnpm, Docker (Supabase local).

```bash
make db     # Supabase local (supabase start)
make api    # http://localhost:8000/healthz
make web    # http://localhost:3000
make dev    # todo junto
make lint typecheck test build
```

> `make db` (`supabase start`) necesita Docker en ejecución. En T010 Docker estaba apagado, así que `supabase start` no se verificó.
