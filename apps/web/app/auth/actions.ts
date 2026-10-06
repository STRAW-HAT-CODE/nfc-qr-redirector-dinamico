"use server";

import { headers } from "next/headers";
import { redirect } from "next/navigation";

import { safeNext } from "@/lib/safe-next";
import { createClient } from "@/lib/supabase/server";

export interface AuthState {
  error?: string;
  message?: string;
}

const EMAIL_RE = /^[^@\s]+@[^@\s]+\.[^@\s]+$/;

async function origin() {
  const h = await headers();
  const o = h.get("origin");
  if (o) return o;
  const host = h.get("x-forwarded-host") ?? h.get("host");
  const proto = h.get("x-forwarded-proto") ?? (host?.startsWith("localhost") ? "http" : "https");
  return `${proto}://${host}`;
}

function credentials(formData: FormData) {
  return {
    email: String(formData.get("email") ?? "").trim(),
    password: String(formData.get("password") ?? ""),
  };
}

export async function login(_: AuthState, formData: FormData): Promise<AuthState> {
  const { email, password } = credentials(formData);
  if (!EMAIL_RE.test(email)) return { error: "Introduce un email válido." };
  if (!password) return { error: "Introduce tu contraseña." };

  const supabase = await createClient();
  const { error } = await supabase.auth.signInWithPassword({ email, password });
  if (error) {
    return {
      error:
        error.code === "email_not_confirmed"
          ? "Confirma tu email antes de iniciar sesión."
          : "Email o contraseña incorrectos.",
    };
  }
  redirect(safeNext(String(formData.get("next") ?? "")));
}

export async function signup(_: AuthState, formData: FormData): Promise<AuthState> {
  const { email, password } = credentials(formData);
  if (!EMAIL_RE.test(email)) return { error: "Introduce un email válido." };
  if (password.length < 8) return { error: "La contraseña debe tener al menos 8 caracteres." };

  const supabase = await createClient();
  const { data, error } = await supabase.auth.signUp({
    email,
    password,
    options: { emailRedirectTo: `${await origin()}/auth/callback` },
  });
  if (error) return { error: "No se pudo crear la cuenta. Revisa los datos e inténtalo de nuevo." };
  // Con confirmación de email activa no hay sesión hasta confirmar.
  if (data.session) redirect("/orgs");
  return { message: "Te enviamos un email para confirmar tu cuenta." };
}

export async function magicLink(_: AuthState, formData: FormData): Promise<AuthState> {
  const { email } = credentials(formData);
  if (!EMAIL_RE.test(email)) return { error: "Introduce un email válido." };

  const supabase = await createClient();
  const { error } = await supabase.auth.signInWithOtp({
    email,
    options: { emailRedirectTo: `${await origin()}/auth/callback` },
  });
  if (error) return { error: "No se pudo enviar el enlace. Inténtalo de nuevo en un momento." };
  return { message: "Revisa tu email: te enviamos un enlace para entrar." };
}

export async function logout() {
  const supabase = await createClient();
  await supabase.auth.signOut();
  redirect("/login");
}
