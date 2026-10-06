"use client";

import Link from "next/link";
import { useActionState, useEffect, useState } from "react";
import { toast } from "sonner";

import { createLinkAction } from "@/app/(app)/links/actions";
import { Button } from "@/components/ui/button";
import { Label } from "@/components/ui/label";
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from "@/components/ui/select";

import { FieldError, TextField, WindowFields, type FieldErrors } from "./link-fields";
import { validateHttpUrl, type ActionState } from "./types";

export function LinkForm() {
  const [state, action, pending] = useActionState<ActionState, FormData>(createLinkAction, {});
  const [clientErrors, setClientErrors] = useState<FieldErrors>({});
  const [status, setStatus] = useState(state.values?.status ?? "active");
  const errors = { ...state.fieldErrors, ...clientErrors };
  const v = state.values ?? {};

  useEffect(() => {
    if (state.error) toast.error(state.error);
  }, [state]);

  return (
    <form
      action={action}
      noValidate
      className="grid max-w-2xl gap-5"
      onSubmit={(e) => {
        const fd = new FormData(e.currentTarget);
        const fe: FieldErrors = {};
        if (!String(fd.get("name") ?? "").trim()) fe.name = "Introduce un nombre.";
        const d = validateHttpUrl(String(fd.get("destination_url") ?? ""), true);
        if (d) fe.destination_url = d;
        const f = validateHttpUrl(String(fd.get("fallback_url") ?? ""), false);
        if (f) fe.fallback_url = f;
        setClientErrors(fe);
        if (Object.keys(fe).length) e.preventDefault();
      }}
    >
      <TextField name="name" label="Nombre" defaultValue={v.name} error={errors.name} required maxLength={120} placeholder="Menú de la carta" />
      <TextField
        name="destination_url"
        label="URL de destino"
        type="url"
        defaultValue={v.destination_url}
        error={errors.destination_url}
        required
        placeholder="https://ejemplo.com/pagina"
        hint="Solo http o https. Podrás cambiarla después sin reimprimir el QR."
      />
      <TextField
        name="fallback_url"
        label="URL de respaldo (opcional)"
        type="url"
        defaultValue={v.fallback_url}
        error={errors.fallback_url}
        placeholder="https://ejemplo.com/no-disponible"
        hint="Dónde enviar a quien escanee si el enlace está pausado o fuera de vigencia."
      />
      <WindowFields key={`${v.starts_at}|${v.expires_at}`} starts={v.starts_at} expires={v.expires_at} error={errors.window} />
      <div className="grid gap-1.5">
        <Label htmlFor="status-trigger">Estado inicial</Label>
        <input type="hidden" name="status" value={status} />
        <Select value={status} onValueChange={setStatus}>
          <SelectTrigger id="status-trigger" className="w-full sm:w-56">
            <SelectValue />
          </SelectTrigger>
          <SelectContent>
            <SelectItem value="active">Activo</SelectItem>
            <SelectItem value="paused">Pausado</SelectItem>
          </SelectContent>
        </Select>
      </div>
      {state.error && !state.fieldErrors ? <FieldError id="form-error" message={state.error} /> : null}
      <div className="flex gap-2">
        <Button type="submit" disabled={pending}>
          {pending ? "Creando…" : "Crear enlace"}
        </Button>
        <Button asChild variant="ghost">
          <Link href="/links">Cancelar</Link>
        </Button>
      </div>
    </form>
  );
}
