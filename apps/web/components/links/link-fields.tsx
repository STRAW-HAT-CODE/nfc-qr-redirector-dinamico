"use client";

import { useState } from "react";

import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";

import type { ActionState } from "./types";

export function FieldError({ id, message }: { id: string; message?: string }) {
  if (!message) return null;
  return (
    <p id={id} role="alert" className="text-sm text-destructive">
      {message}
    </p>
  );
}

/** ISO (UTC) → valor para <input type="datetime-local"> en hora local. */
function toLocalInput(iso: string | null | undefined) {
  if (!iso) return "";
  const d = new Date(iso);
  if (Number.isNaN(d.getTime())) return "";
  const p = (n: number) => String(n).padStart(2, "0");
  return `${d.getFullYear()}-${p(d.getMonth() + 1)}-${p(d.getDate())}T${p(d.getHours())}:${p(d.getMinutes())}`;
}

const toIso = (local: string) => (local ? new Date(local).toISOString() : "");

/** Vigencia: se muestra en hora local y se envía en ISO UTC. */
export function WindowFields({
  starts,
  expires,
  error,
  disabled,
}: {
  starts?: string | null;
  expires?: string | null;
  error?: string;
  disabled?: boolean;
}) {
  const [s, setS] = useState(toLocalInput(starts));
  const [x, setX] = useState(toLocalInput(expires));
  return (
    <fieldset className="grid gap-3" disabled={disabled} aria-describedby={error ? "window-error" : undefined}>
      <legend className="mb-1 text-sm font-medium">Vigencia (opcional)</legend>
      <div className="grid gap-3 sm:grid-cols-2">
        <div className="grid gap-1.5">
          <Label htmlFor="starts_at_local">Inicia</Label>
          <Input id="starts_at_local" type="datetime-local" value={s} onChange={(e) => setS(e.target.value)} />
          <input type="hidden" name="starts_at" value={toIso(s)} />
        </div>
        <div className="grid gap-1.5">
          <Label htmlFor="expires_at_local">Vence</Label>
          <Input id="expires_at_local" type="datetime-local" value={x} onChange={(e) => setX(e.target.value)} />
          <input type="hidden" name="expires_at" value={toIso(x)} />
        </div>
      </div>
      <FieldError id="window-error" message={error} />
    </fieldset>
  );
}

export function TextField({
  name,
  label,
  defaultValue,
  error,
  placeholder,
  hint,
  type = "text",
  required,
  disabled,
  maxLength,
}: {
  name: string;
  label: string;
  defaultValue?: string;
  error?: string;
  placeholder?: string;
  hint?: string;
  type?: string;
  required?: boolean;
  disabled?: boolean;
  maxLength?: number;
}) {
  return (
    <div className="grid gap-1.5">
      <Label htmlFor={name}>{label}</Label>
      <Input
        id={name}
        name={name}
        type={type}
        defaultValue={defaultValue}
        placeholder={placeholder}
        required={required}
        disabled={disabled}
        maxLength={maxLength}
        aria-invalid={error ? true : undefined}
        aria-describedby={[error ? `${name}-error` : "", hint ? `${name}-hint` : ""].filter(Boolean).join(" ") || undefined}
      />
      {hint ? (
        <p id={`${name}-hint`} className="text-xs text-muted-foreground">
          {hint}
        </p>
      ) : null}
      <FieldError id={`${name}-error`} message={error} />
    </div>
  );
}

export type FieldErrors = NonNullable<ActionState["fieldErrors"]>;
