"use server";

import { revalidatePath } from "next/cache";

import {
  ApiError,
  adminBlockDomain,
  adminFindLink,
  adminSetLinkStatus,
  adminUnblockDomain,
  adminUpdateOrg,
  type AdminLink,
  type PlanLimits,
} from "@/lib/api";

export interface PlatformResult<T = undefined> {
  ok: boolean;
  message?: string;
  data?: T;
}

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const PLAN_RE = /^[a-z][a-z0-9_-]{0,31}$/;
const LIMIT_KEYS = ["max_links", "max_members", "max_nfc_tags", "max_logos", "scans_retention_days"];
const DOMAIN_RE = /^(?=.{1,253}$)([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}$/;

function fail(e: unknown): PlatformResult<never> {
  if (e instanceof ApiError) {
    if (e.status === 403) return { ok: false, message: "No tienes permiso de platform admin." };
    return { ok: false, message: e.message };
  }
  throw e;
}

/** Valida el JSON de overrides: objeto con claves conocidas y enteros ≥ 0 (o null). */
export async function parseLimits(raw: string): Promise<{ ok: true; value: PlanLimits } | { ok: false; message: string }> {
  let parsed: unknown;
  try {
    parsed = JSON.parse(raw.trim() || "{}");
  } catch {
    return { ok: false, message: "JSON no válido." };
  }
  if (typeof parsed !== "object" || parsed === null || Array.isArray(parsed)) {
    return { ok: false, message: "Debe ser un objeto JSON, p. ej. {\"max_links\": 100}." };
  }
  for (const [k, v] of Object.entries(parsed)) {
    if (!LIMIT_KEYS.includes(k)) return { ok: false, message: `Clave desconocida: ${k}. Permitidas: ${LIMIT_KEYS.join(", ")}.` };
    if (v !== null && !(typeof v === "number" && Number.isInteger(v) && v >= 0 && v <= 999_999_999)) {
      return { ok: false, message: `${k} debe ser un entero ≥ 0 o null (sin límite).` };
    }
  }
  return { ok: true, value: parsed as PlanLimits };
}

export async function updateOrgPlanAction(orgId: string, plan: string, limitsJson: string): Promise<PlatformResult> {
  if (!UUID_RE.test(orgId)) return { ok: false, message: "Organización no válida." };
  if (!PLAN_RE.test(plan)) return { ok: false, message: "Plan no válido." };
  const limits = await parseLimits(limitsJson);
  if (!limits.ok) return { ok: false, message: limits.message };
  try {
    await adminUpdateOrg(orgId, { plan, limits: limits.value });
  } catch (e) {
    return fail(e);
  }
  revalidatePath("/platform");
  return { ok: true, message: "Plan y límites actualizados." };
}

export async function setOrgStatusAction(orgId: string, status: "active" | "suspended"): Promise<PlatformResult> {
  if (!UUID_RE.test(orgId) || (status !== "active" && status !== "suspended")) return { ok: false, message: "Datos no válidos." };
  try {
    await adminUpdateOrg(orgId, { status });
  } catch (e) {
    return fail(e);
  }
  revalidatePath("/platform");
  return { ok: true, message: status === "suspended" ? "Organización suspendida." : "Organización reactivada." };
}

export async function blockDomainAction(input: string): Promise<PlatformResult> {
  const domain = input.trim().toLowerCase().replace(/^\.+|\.+$/g, "");
  if (!DOMAIN_RE.test(domain)) return { ok: false, message: "Introduce un dominio válido, p. ej. malo.example." };
  try {
    await adminBlockDomain(domain);
  } catch (e) {
    return fail(e);
  }
  revalidatePath("/platform/domains");
  return { ok: true, message: `Dominio ${domain} bloqueado.` };
}

export async function unblockDomainAction(domain: string): Promise<PlatformResult> {
  if (!DOMAIN_RE.test(domain)) return { ok: false, message: "Dominio no válido." };
  try {
    await adminUnblockDomain(domain);
  } catch (e) {
    return fail(e);
  }
  revalidatePath("/platform/domains");
  return { ok: true, message: `Dominio ${domain} desbloqueado.` };
}

export async function findLinkAction(slug: string): Promise<PlatformResult<AdminLink[]>> {
  const s = slug.trim();
  if (!/^[A-Za-z0-9_-]{1,64}$/.test(s)) return { ok: false, message: "Slug no válido (letras, números, - y _)." };
  try {
    const res = await adminFindLink(s);
    return { ok: true, data: Array.isArray(res) ? res : res ? [res as AdminLink] : [] };
  } catch (e) {
    if (e instanceof ApiError && e.status === 404) return { ok: true, data: [] };
    return fail(e);
  }
}

export async function setLinkStatusAction(
  linkId: string,
  status: "active" | "paused" | "archived",
): Promise<PlatformResult> {
  if (!UUID_RE.test(linkId) || !["active", "paused", "archived"].includes(status)) return { ok: false, message: "Datos no válidos." };
  try {
    await adminSetLinkStatus(linkId, status);
  } catch (e) {
    return fail(e);
  }
  return { ok: true, message: status === "active" ? "Enlace reactivado." : "Enlace suspendido." };
}
