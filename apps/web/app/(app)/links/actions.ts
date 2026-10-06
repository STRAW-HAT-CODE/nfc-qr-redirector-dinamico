"use server";

import { revalidatePath } from "next/cache";
import { redirect } from "next/navigation";

import { api, ApiError } from "@/lib/api";
import { validateHttpUrl, type ActionState, type LinkItem, type LinkStatus } from "@/components/links/types";

const str = (fd: FormData, k: string) => String(fd.get(k) ?? "").trim();
const optional = (fd: FormData, k: string) => str(fd, k) || null;

const raw = (fd: FormData): Record<string, string> =>
  Object.fromEntries([...fd.entries()].filter(([, v]) => typeof v === "string")) as Record<string, string>;

function isUrlCode(code: string) {
  return code.startsWith("url_");
}

/** Traduce un error de la API a error de campo cuando es posible. */
function toState(e: unknown, urlField: "destination_url" | "fallback_url" = "destination_url"): ActionState {
  if (!(e instanceof ApiError)) throw e;
  if (e.status === 422 || e.status === 400) {
    if (isUrlCode(e.code)) return { error: e.message, fieldErrors: { [urlField]: e.message } };
    if (e.code === "invalid_window") return { error: e.message, fieldErrors: { window: e.message } };
  }
  return { error: e.message };
}

function checkCommon(fd: FormData): NonNullable<ActionState["fieldErrors"]> {
  const fe: NonNullable<ActionState["fieldErrors"]> = {};
  const name = str(fd, "name");
  if (!name || name.length > 120) fe.name = "Introduce un nombre (máx. 120 caracteres).";
  const fb = validateHttpUrl(str(fd, "fallback_url"), false);
  if (fb) fe.fallback_url = fb;
  const s = optional(fd, "starts_at");
  const x = optional(fd, "expires_at");
  if (s && x && new Date(s) >= new Date(x)) fe.window = "El inicio debe ser anterior al vencimiento.";
  return fe;
}

export async function createLinkAction(_: ActionState, fd: FormData): Promise<ActionState> {
  const fieldErrors = checkCommon(fd);
  const dest = validateHttpUrl(str(fd, "destination_url"), true);
  if (dest) fieldErrors.destination_url = dest;
  if (Object.keys(fieldErrors).length) return { fieldErrors, values: raw(fd) };

  let created: LinkItem;
  try {
    created = await api<LinkItem>("/v1/links", {
      method: "POST",
      body: {
        name: str(fd, "name"),
        destination_url: str(fd, "destination_url"),
        fallback_url: optional(fd, "fallback_url"),
        starts_at: optional(fd, "starts_at"),
        expires_at: optional(fd, "expires_at"),
        status: str(fd, "status") === "paused" ? "paused" : "active",
      },
    });
  } catch (e) {
    return { ...toState(e), values: raw(fd) };
  }
  revalidatePath("/links");
  redirect(`/links/${created.id}`);
}

export async function updateLinkAction(id: string, _: ActionState, fd: FormData): Promise<ActionState> {
  const fieldErrors = checkCommon(fd);
  if (Object.keys(fieldErrors).length) return { fieldErrors, values: raw(fd) };
  try {
    await api<LinkItem>(`/v1/links/${encodeURIComponent(id)}`, {
      method: "PATCH",
      body: {
        name: str(fd, "name"),
        fallback_url: optional(fd, "fallback_url"),
        starts_at: optional(fd, "starts_at"),
        expires_at: optional(fd, "expires_at"),
      },
    });
  } catch (e) {
    return { ...toState(e, "fallback_url"), values: raw(fd) };
  }
  revalidatePath(`/links/${id}`);
  revalidatePath("/links");
  return { ok: true };
}

export async function updateDestinationAction(id: string, _: ActionState, fd: FormData): Promise<ActionState> {
  const dest = validateHttpUrl(str(fd, "destination_url"), true);
  if (dest) return { fieldErrors: { destination_url: dest }, values: raw(fd) };
  try {
    await api<LinkItem>(`/v1/links/${encodeURIComponent(id)}/destination`, {
      method: "PATCH",
      body: { destination_url: str(fd, "destination_url") },
    });
  } catch (e) {
    return { ...toState(e), values: raw(fd) };
  }
  revalidatePath(`/links/${id}`);
  revalidatePath("/links");
  return { ok: true };
}

export async function setStatusAction(id: string, status: LinkStatus): Promise<ActionState> {
  try {
    if (status === "archived") {
      await api<LinkItem>(`/v1/links/${encodeURIComponent(id)}`, { method: "DELETE" });
    } else {
      await api<LinkItem>(`/v1/links/${encodeURIComponent(id)}`, { method: "PATCH", body: { status } });
    }
  } catch (e) {
    return toState(e);
  }
  revalidatePath(`/links/${id}`);
  revalidatePath("/links");
  return { ok: true };
}
