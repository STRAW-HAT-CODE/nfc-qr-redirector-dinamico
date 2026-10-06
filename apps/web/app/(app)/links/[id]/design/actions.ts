"use server";

import { revalidatePath } from "next/cache";

import { api, ApiError, type QrDesign } from "@/lib/api";

export type SaveResult = { ok: true; design: QrDesign } | { ok: false; message: string };

export interface DesignInput {
  fg: string;
  bg: string;
  ecc_level: QrDesign["ecc_level"];
  frame: QrDesign["frame"];
  module_style: QrDesign["module_style"];
  margin: number;
  frame_text: string | null;
}

export async function saveDesignAction(linkId: string, v: DesignInput): Promise<SaveResult> {
  try {
    const design = await api<QrDesign>(`/v1/links/${encodeURIComponent(linkId)}/design`, {
      method: "PUT",
      body: { ...v, frame_text: v.frame_text?.trim() || null },
    });
    revalidatePath(`/links/${linkId}/design`);
    return { ok: true, design };
  } catch (e) {
    if (e instanceof ApiError) {
      if (e.status === 403) return { ok: false, message: "No tienes permiso para editar el diseño." };
      return { ok: false, message: e.message };
    }
    throw e;
  }
}
