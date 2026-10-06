"use server";

import { revalidatePath } from "next/cache";

import { api, ApiError } from "@/lib/api";
import type { NfcActionResult } from "@/components/nfc/types";

const base = (linkId: string) => `/v1/links/${encodeURIComponent(linkId)}/nfc-tags`;

async function run(linkId: string, ok: string, fn: () => Promise<unknown>): Promise<NfcActionResult> {
  try {
    await fn();
  } catch (e) {
    if (e instanceof ApiError) {
      if (e.status === 403) return { ok: false, message: "No tienes permiso para esta acción." };
      if (e.status === 409) return { ok: false, message: "Ya existe una etiqueta con ese UID en la organización." };
      return { ok: false, message: e.message };
    }
    throw e;
  }
  revalidatePath(`/links/${linkId}/nfc`);
  return { ok: true, message: ok };
}

interface TagInput {
  label: string;
  location: string;
  uid: string;
}

export async function createTagAction(linkId: string, v: TagInput): Promise<NfcActionResult> {
  const label = v.label.trim();
  if (!label || label.length > 80) return { ok: false, message: "El nombre es obligatorio (máx. 80 caracteres)." };
  return run(linkId, "Etiqueta creada", () =>
    api(base(linkId), {
      method: "POST",
      body: { label, location: v.location.trim() || null, uid: v.uid.trim() || null },
    }),
  );
}

export async function updateTagAction(linkId: string, tagId: string, v: TagInput): Promise<NfcActionResult> {
  const label = v.label.trim();
  if (!label || label.length > 80) return { ok: false, message: "El nombre es obligatorio (máx. 80 caracteres)." };
  return run(linkId, "Etiqueta actualizada", () =>
    api(`${base(linkId)}/${encodeURIComponent(tagId)}`, {
      method: "PATCH",
      body: { label, location: v.location.trim() || null, uid: v.uid.trim() || null },
    }),
  );
}

export async function deleteTagAction(linkId: string, tagId: string): Promise<NfcActionResult> {
  return run(linkId, "Etiqueta eliminada", () =>
    api(`${base(linkId)}/${encodeURIComponent(tagId)}`, { method: "DELETE" }),
  );
}
