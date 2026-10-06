# ADR-0002 · Stack técnico

- Estado: Aceptado
- Fecha: 2026-10-05

## Contexto
El usuario pidió Python y Supabase, con un dashboard visual.

## Decisión
FastAPI (Python 3.12, uv, pydantic v2, segno, Pillow) para API y redirector; Next.js + shadcn/ui para el dashboard; Supabase (Postgres, Auth, Storage, pg_cron); deploy en Vercel.

## Alternativas descartadas
Todo Python con plantillas server-side; Fastify + Next.js.

## Consecuencias
Dos lenguajes en el monorepo; la generación de QR queda en Python, donde las librerías son más maduras.
