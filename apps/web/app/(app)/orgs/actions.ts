"use server";

import { cookies } from "next/headers";
import { redirect } from "next/navigation";

import { ACTIVE_ORG_COOKIE, ApiError, createOrg, listOrgs } from "@/lib/api";

export interface CreateOrgState {
  error?: string;
  fieldErrors?: { name?: string; slug?: string };
}

const SLUG_RE = /^[a-z0-9][a-z0-9-]{1,61}[a-z0-9]$/;

async function setActiveOrgCookie(id: string) {
  (await cookies()).set(ACTIVE_ORG_COOKIE, id, {
    path: "/",
    httpOnly: true,
    sameSite: "lax",
    secure: process.env.NODE_ENV === "production",
    maxAge: 60 * 60 * 24 * 365,
  });
}

export async function selectOrg(formData: FormData) {
  const id = String(formData.get("orgId") ?? "");
  // Solo se acepta una org de la que el usuario es miembro.
  const orgs = await listOrgs();
  if (!orgs.some((o) => o.id === id)) redirect("/orgs");
  await setActiveOrgCookie(id);
  redirect("/links");
}

export async function createOrgAction(_: CreateOrgState, formData: FormData): Promise<CreateOrgState> {
  const name = String(formData.get("name") ?? "").trim();
  const slug = String(formData.get("slug") ?? "").trim().toLowerCase();

  const fieldErrors: CreateOrgState["fieldErrors"] = {};
  if (!name || name.length > 120) fieldErrors.name = "Introduce un nombre (máx. 120 caracteres).";
  if (!SLUG_RE.test(slug)) {
    fieldErrors.slug = "3–63 caracteres: minúsculas, números y guiones; sin guion al inicio o final.";
  }
  if (fieldErrors.name || fieldErrors.slug) return { fieldErrors };

  let id: string;
  try {
    id = (await createOrg({ name, slug })).id;
  } catch (e) {
    if (e instanceof ApiError) {
      if (e.status === 409) return { fieldErrors: { slug: "Ese identificador ya está en uso." } };
      return { error: e.message };
    }
    throw e;
  }
  await setActiveOrgCookie(id);
  redirect("/links");
}
