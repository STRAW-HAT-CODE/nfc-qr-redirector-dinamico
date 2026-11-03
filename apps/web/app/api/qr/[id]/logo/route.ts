import type { NextRequest } from "next/server";

import { apiRaw } from "@/lib/api";

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
type Ctx = { params: Promise<{ id: string }> };

const passthrough = (res: Response) =>
  new Response(res.body, { status: res.status, headers: { "Content-Type": res.headers.get("content-type") ?? "application/json" } });

/** Lee o sube el logo (multipart) con el token del servidor; evita el límite de 1 MB de las Server Actions. */
export async function GET(_req: NextRequest, ctx: Ctx) {
  const { id } = await ctx.params;
  if (!UUID.test(id)) return Response.json({ error: { code: "bad_request", message: "Id inválido." } }, { status: 400 });
  const res = await apiRaw(`/v1/links/${id}/design/logo`);
  return new Response(res.body, {
    status: res.status,
    headers: {
      "Content-Type": res.headers.get("content-type") ?? "image/png",
      "Cache-Control": "private, no-store",
      "X-Content-Type-Options": "nosniff",
    },
  });
}
export async function POST(req: NextRequest, ctx: Ctx) {
  const { id } = await ctx.params;
  if (!UUID.test(id)) return Response.json({ error: { code: "bad_request", message: "Id inválido." } }, { status: 400 });
  const type = req.headers.get("content-type");
  if (!type?.startsWith("multipart/form-data")) {
    return Response.json({ error: { code: "bad_request", message: "Se esperaba multipart." } }, { status: 400 });
  }
  const body = await req.arrayBuffer();
  if (body.byteLength > 1_048_576) {
    return Response.json({ error: { code: "logo_too_large", message: "El logo supera 1 MB." } }, { status: 413 });
  }
  return passthrough(await apiRaw(`/v1/links/${id}/design/logo`, { method: "POST", body, contentType: type }));
}

export async function DELETE(_req: NextRequest, ctx: Ctx) {
  const { id } = await ctx.params;
  if (!UUID.test(id)) return Response.json({ error: { code: "bad_request", message: "Id inválido." } }, { status: 400 });
  return passthrough(await apiRaw(`/v1/links/${id}/design/logo`, { method: "DELETE" }));
}
