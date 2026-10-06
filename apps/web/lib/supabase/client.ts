import { createBrowserClient } from "@supabase/ssr";

import { supabaseEnv } from "./env";

/** Cliente de navegador (solo componentes cliente). */
export function createClient() {
  const { url, anonKey } = supabaseEnv();
  return createBrowserClient(url, anonKey);
}
