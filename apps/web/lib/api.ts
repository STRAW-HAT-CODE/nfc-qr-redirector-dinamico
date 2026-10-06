import "server-only";

import { cookies } from "next/headers";
import { redirect } from "next/navigation";

import { createClient } from "@/lib/supabase/server";

/** Cookie con la organización activa (se envía como X-Org-Id). */
export const ACTIVE_ORG_COOKIE = "dqr_org";

export type Role = "viewer" | "editor" | "admin" | "owner";

export interface Org {
  id: string;
  name: string;
  slug: string;
  plan: string;
  status: string;
  created_at: string;
}

export interface MyOrg extends Org {
  role: Role;
}

/** Error de la API: formato `{ error: { code, message } }` (docs/04-api.md). */
export class ApiError extends Error {
  constructor(
    public readonly status: number,
    public readonly code: string,
    message: string,
  ) {
    super(message);
    this.name = "ApiError";
  }
}

interface RequestOptions {
  method?: "GET" | "POST" | "PATCH" | "PUT" | "DELETE";
  body?: unknown;
  /** Por defecto usa la org activa de la cookie. `false` = no enviar X-Org-Id. */
  orgId?: string | false;
}

function baseUrl() {
  return (process.env.NEXT_PUBLIC_API_URL ?? "http://localhost:8000").replace(/\/$/, "");
}

export async function api<T>(path: string, opts: RequestOptions = {}): Promise<T> {
  const supabase = await createClient();
  // El token solo se reenvía; la API lo valida. La identidad se verificó con getClaims() en el proxy.
  const {
    data: { session },
  } = await supabase.auth.getSession();
  if (!session) redirect("/login");

  const headers: Record<string, string> = {
    Authorization: `Bearer ${session.access_token}`,
    Accept: "application/json",
  };
  if (opts.body !== undefined) headers["Content-Type"] = "application/json";
  const orgId = opts.orgId === false ? undefined : (opts.orgId ?? (await getActiveOrgId()));
  if (orgId) headers["X-Org-Id"] = orgId;

  let res: Response;
  try {
    res = await fetch(`${baseUrl()}${path}`, {
      method: opts.method ?? "GET",
      headers,
      body: opts.body !== undefined ? JSON.stringify(opts.body) : undefined,
      cache: "no-store",
    });
  } catch {
    throw new ApiError(0, "network_error", "No se pudo conectar con la API.");
  }

  if (res.status === 401) redirect("/login");
  if (!res.ok) {
    let code = "unknown_error";
    let message = `Error ${res.status}`;
    try {
      const data = (await res.json()) as { error?: { code?: string; message?: string } };
      if (data.error) {
        code = data.error.code ?? code;
        message = data.error.message ?? message;
      }
    } catch {
      /* cuerpo no JSON */
    }
    throw new ApiError(res.status, code, message);
  }
  if (res.status === 204) return undefined as T;
  return (await res.json()) as T;
}

export async function getActiveOrgId(): Promise<string | undefined> {
  return (await cookies()).get(ACTIVE_ORG_COOKIE)?.value;
}

export const listOrgs = () => api<MyOrg[]>("/v1/orgs", { orgId: false });

export const createOrg = (input: { name: string; slug: string }) =>
  api<Org>("/v1/orgs", { method: "POST", body: input, orgId: false });

/** Orgs del usuario + la activa (la de la cookie si sigue siendo válida). */
export async function getOrgContext() {
  const orgs = await listOrgs();
  const activeId = await getActiveOrgId();
  const active = orgs.find((o) => o.id === activeId) ?? null;
  return { orgs, active };
}

/** Para pantallas que necesitan org: redirige a /orgs si no hay una activa. */
export async function requireActiveOrg() {
  const ctx = await getOrgContext();
  if (!ctx.active) redirect("/orgs");
  return { ...ctx, active: ctx.active };
}

const ROLE_RANK: Record<Role, number> = { viewer: 0, editor: 1, admin: 2, owner: 3 };
export const hasRole = (role: Role, min: Role) => ROLE_RANK[role] >= ROLE_RANK[min];

export interface Member {
  org_id: string;
  user_id: string;
  role: Role;
  created_at: string;
}

export const listMembers = (orgId: string) => api<Member[]>(`/v1/orgs/${orgId}/members`, { orgId });

/* ── Stats (contrato de apps/api/app/schemas/stats.py) ───────────────────── */

export type StatsGroup = "day" | "channel" | "country" | "device";

export interface StatsPoint {
  key: string;
  scans: number;
  /** Solo informado con group=day. */
  unique_visitors: number | null;
}

export interface Stats {
  group: StatsGroup;
  from: string;
  to: string;
  totals: { scans: number; unique_visitors: number };
  series: StatsPoint[];
}

/** Las 4 agrupaciones en paralelo. `linkId` → métricas del enlace; si no, de la org activa. */
export async function getStatsBundle(orgId: string, range: { from: string; to: string }, linkId?: string) {
  const base = linkId ? `/v1/links/${encodeURIComponent(linkId)}/stats` : `/v1/orgs/${encodeURIComponent(orgId)}/stats`;
  const get = (group: StatsGroup) => api<Stats>(`${base}?from=${range.from}&to=${range.to}&group=${group}`, { orgId });
  const [day, channel, country, device] = await Promise.all([
    get("day"),
    get("channel"),
    get("country"),
    get("device"),
  ]);
  return { day, channel, country, device };
}
