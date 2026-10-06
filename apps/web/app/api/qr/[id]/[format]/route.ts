import type { NextRequest } from "next/server";

import { apiRaw } from "@/lib/api";

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const FORMATS = new Set(["png", "svg", "pdf"]);
const TEMPLATES = new Set(["none"]); // T033 añadirá sticker/display/poster

const bad = (message: string) => Response.json({ error: { code: "bad_request", message } }, { status: 400 });

/** Proxy de descarga: reenvía a /v1/links/{id}/qr.{fmt} con el token del servidor. */
export async function GET(req: NextRequest, ctx: { params: Promise<{ id: string; format: string }> }) {
  const { id, format } = await ctx.params;
  if (!UUID.test(id) || !FORMATS.has(format)) return bad("Parámetros inválidos.");

  const sp = req.nextUrl.searchParams;
  const q = new URLSearchParams();
  const size = sp.get("size");
  if (size !== null) {
    const n = Number(size);
    if (!Number.isInteger(n) || n < 128 || n > 4096) return bad("size fuera de rango.");
    q.set("size", String(n));
  }
  const template = sp.get("template");
  if (template !== null) {
    if (!TEMPLATES.has(template)) return bad("template no soportado.");
    q.set("template", template);
  }

  const res = await apiRaw(`/v1/links/${id}/qr.${format}${q.size ? `?${q}` : ""}`);
  const headers = new Headers();
  for (const h of ["content-type", "content-disposition", "x-qr-warnings"]) {
    const v = res.headers.get(h);
    if (v) headers.set(h, v);
  }
  headers.set("Cache-Control", "private, no-store");
  headers.set("X-Content-Type-Options", "nosniff");
  return new Response(res.body, { status: res.status, headers });
}
