"use server";

import { revalidatePath } from "next/cache";

import { ApiError, api, getActiveOrgId, type Role } from "@/lib/api";

export interface MemberActionResult {
  ok: boolean;
  /** Mensaje listo para mostrar al usuario. */
  message?: string;
  code?: string;
}

const ROLES: Role[] = ["viewer", "editor", "admin", "owner"];
const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

function fail(e: unknown): MemberActionResult {
  if (e instanceof ApiError) {
    if (e.code === "last_owner") return { ok: false, code: e.code, message: "No puedes quitar al último owner." };
    if (e.code === "email_lookup_unavailable") {
      return { ok: false, code: e.code, message: "Invitación por email: próximamente." };
    }
    return { ok: false, code: e.code, message: e.message };
  }
  throw e;
}

async function orgBase() {
  const org = await getActiveOrgId();
  if (!org) return null;
  return { org, path: `/v1/orgs/${org}/members` };
}

export async function addMemberAction(input: { user_id: string; role: Role }): Promise<MemberActionResult> {
  const userId = input.user_id.trim();
  if (!UUID_RE.test(userId)) return { ok: false, message: "Introduce un user_id válido (UUID)." };
  if (!ROLES.includes(input.role)) return { ok: false, message: "Rol no válido." };
  const base = await orgBase();
  if (!base) return { ok: false, message: "No hay organización activa." };
  try {
    await api(base.path, { method: "POST", body: { user_id: userId, role: input.role }, orgId: base.org });
  } catch (e) {
    return fail(e);
  }
  revalidatePath("/settings/members");
  return { ok: true, message: "Miembro añadido." };
}

export async function changeRoleAction(userId: string, role: Role): Promise<MemberActionResult> {
  if (!UUID_RE.test(userId) || !ROLES.includes(role)) return { ok: false, message: "Datos no válidos." };
  const base = await orgBase();
  if (!base) return { ok: false, message: "No hay organización activa." };
  try {
    await api(`${base.path}/${userId}`, { method: "PATCH", body: { role }, orgId: base.org });
  } catch (e) {
    return fail(e);
  }
  revalidatePath("/settings/members");
  return { ok: true, message: "Rol actualizado." };
}

export async function removeMemberAction(userId: string): Promise<MemberActionResult> {
  if (!UUID_RE.test(userId)) return { ok: false, message: "Datos no válidos." };
  const base = await orgBase();
  if (!base) return { ok: false, message: "No hay organización activa." };
  try {
    await api(`${base.path}/${userId}`, { method: "DELETE", orgId: base.org });
  } catch (e) {
    return fail(e);
  }
  revalidatePath("/settings/members");
  return { ok: true, message: "Miembro quitado." };
}
