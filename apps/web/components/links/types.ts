export type LinkStatus = "active" | "paused" | "archived";

export interface LinkItem {
  id: string;
  org_id: string;
  slug: string;
  short_url: string;
  name: string;
  destination_url: string;
  fallback_url: string | null;
  status: LinkStatus;
  starts_at: string | null;
  expires_at: string | null;
  created_at: string;
  updated_at: string;
}

export interface Page<T> {
  items: T[];
  limit: number;
  offset: number;
  has_more: boolean;
}

export interface HistoryItem {
  id: number;
  link_id: string;
  old_url: string;
  new_url: string;
  changed_by: string | null;
  changed_at: string;
}

export const STATUS_LABEL: Record<LinkStatus, string> = {
  active: "Activo",
  paused: "Pausado",
  archived: "Archivado",
};

/** Resultado común de las Server Actions de mutación. */
export interface ActionState {
  error?: string;
  fieldErrors?: Partial<Record<"name" | "destination_url" | "fallback_url" | "window", string>>;
  ok?: boolean;
  /** Valores enviados, para repoblar el formulario tras un error (React 19 resetea el form). */
  values?: Record<string, string>;
}

/** Validación de cliente: solo http/https con host. Devuelve mensaje o undefined. */
export function validateHttpUrl(value: string, required: boolean): string | undefined {
  const v = value.trim();
  if (!v) return required ? "Introduce una URL." : undefined;
  let u: URL;
  try {
    u = new URL(v);
  } catch {
    return "La URL no es válida (ej. https://ejemplo.com).";
  }
  if (u.protocol !== "http:" && u.protocol !== "https:") return "Solo se permiten URLs http o https.";
  if (!u.hostname) return "La URL debe tener un host.";
  return undefined;
}
