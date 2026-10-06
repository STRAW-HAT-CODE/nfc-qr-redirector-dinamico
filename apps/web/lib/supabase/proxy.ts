import { createServerClient } from "@supabase/ssr";
import { NextResponse, type NextRequest } from "next/server";

import { supabaseEnv } from "./env";

const PUBLIC_PREFIXES = ["/login", "/signup", "/auth"];

function isPublic(pathname: string) {
  return PUBLIC_PREFIXES.some((p) => pathname === p || pathname.startsWith(`${p}/`));
}

/**
 * Refresca la sesión de Supabase y protege rutas.
 * Usa getClaims() (valida la firma del JWT); nunca getSession() en servidor.
 */
export async function updateSession(request: NextRequest) {
  let supabaseResponse = NextResponse.next({ request });
  const { url, anonKey } = supabaseEnv();

  const supabase = createServerClient(url, anonKey, {
    cookies: {
      getAll() {
        return request.cookies.getAll();
      },
      setAll(cookiesToSet, headers) {
        cookiesToSet.forEach(({ name, value }) => request.cookies.set(name, value));
        supabaseResponse = NextResponse.next({ request });
        cookiesToSet.forEach(({ name, value, options }) =>
          supabaseResponse.cookies.set(name, value, options),
        );
        Object.entries(headers ?? {}).forEach(([k, v]) => supabaseResponse.headers.set(k, v));
      },
    },
  });

  // No ejecutar código entre createServerClient y getClaims().
  const { data } = await supabase.auth.getClaims();
  const authenticated = Boolean(data?.claims);
  const { pathname } = request.nextUrl;

  const redirectTo = (path: string) => {
    const target = request.nextUrl.clone();
    target.pathname = path;
    target.search = "";
    const res = NextResponse.redirect(target);
    // Conserva las cookies de sesión refrescadas.
    supabaseResponse.cookies.getAll().forEach((c) => res.cookies.set(c));
    return res;
  };

  if (!authenticated && !isPublic(pathname)) return redirectTo("/login");
  if (authenticated && (pathname === "/login" || pathname === "/signup")) {
    return redirectTo("/orgs");
  }
  return supabaseResponse;
}
