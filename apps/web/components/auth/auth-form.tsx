"use client";

import { Loader2 } from "lucide-react";
import Link from "next/link";
import { useActionState, useState } from "react";

import { login, magicLink, signup, type AuthState } from "@/app/auth/actions";
import { Alert, AlertDescription } from "@/components/ui/alert";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";

const initial: AuthState = {};

export function AuthForm({ mode, next }: { mode: "login" | "signup"; next?: string }) {
  const [useMagic, setUseMagic] = useState(false);
  const action = mode === "signup" ? signup : useMagic ? magicLink : login;
  const [state, formAction, pending] = useActionState(action, initial);
  const showPassword = mode === "signup" || !useMagic;

  return (
    <form action={formAction} className="grid gap-4" noValidate>
      {next ? <input type="hidden" name="next" value={next} /> : null}
      {state.error ? (
        <Alert variant="destructive">
          <AlertDescription>{state.error}</AlertDescription>
        </Alert>
      ) : null}
      {state.message ? (
        <Alert>
          <AlertDescription role="status">{state.message}</AlertDescription>
        </Alert>
      ) : null}
      <div className="grid gap-2">
        <Label htmlFor="email">Email</Label>
        <Input id="email" name="email" type="email" autoComplete="email" required />
      </div>
      {showPassword ? (
        <div className="grid gap-2">
          <Label htmlFor="password">Contraseña</Label>
          <Input
            id="password"
            name="password"
            type="password"
            autoComplete={mode === "signup" ? "new-password" : "current-password"}
            minLength={mode === "signup" ? 8 : undefined}
            required
          />
        </div>
      ) : null}
      <Button type="submit" disabled={pending}>
        {pending ? <Loader2 className="animate-spin" aria-hidden="true" /> : null}
        {mode === "signup" ? "Crear cuenta" : useMagic ? "Enviar enlace mágico" : "Iniciar sesión"}
      </Button>
      {mode === "login" ? (
        <Button type="button" variant="ghost" size="sm" onClick={() => setUseMagic((v) => !v)}>
          {useMagic ? "Usar contraseña" : "Entrar con enlace mágico"}
        </Button>
      ) : null}
      <p className="text-center text-sm text-muted-foreground">
        {mode === "login" ? (
          <>¿No tienes cuenta? <Link className="text-primary underline-offset-4 hover:underline" href="/signup">Regístrate</Link></>
        ) : (
          <>¿Ya tienes cuenta? <Link className="text-primary underline-offset-4 hover:underline" href="/login">Inicia sesión</Link></>
        )}
      </p>
    </form>
  );
}
