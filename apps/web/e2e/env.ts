import { existsSync } from "node:fs";
import path from "node:path";

/** Carga apps/api/.env y apps/web/.env.local sin pisar variables ya definidas (p. ej. secrets de CI). */
export function loadE2eEnv() {
  const root = path.resolve(__dirname, "..");
  for (const f of [path.join(root, ".env.local"), path.join(root, "..", "api", ".env")]) {
    if (existsSync(f)) process.loadEnvFile(f);
  }
}

const PLACEHOLDER = /^\[?SENSITIVE\]?$/;

export function realEnv(name: string): string | undefined {
  const v = process.env[name]?.trim();
  return v && !PLACEHOLDER.test(v) ? v : undefined;
}

/** Variables que necesita el E2E (solo nombres; nunca se imprimen los valores). */
export const REQUIRED = ["SUPABASE_URL", "SUPABASE_SERVICE_ROLE_KEY", "SUPABASE_ANON_KEY", "NEXT_PUBLIC_SUPABASE_URL", "NEXT_PUBLIC_SUPABASE_ANON_KEY"] as const;

export function missingEnv() {
  return REQUIRED.filter((n) => !realEnv(n));
}
