"use client";

import { useActionState, useEffect, useState } from "react";
import { toast } from "sonner";

import { updateLinkAction } from "@/app/(app)/links/actions";
import { Button } from "@/components/ui/button";

import { FieldError, TextField, WindowFields, type FieldErrors } from "./link-fields";
import { validateHttpUrl, type ActionState, type LinkItem } from "./types";

export function LinkEditForm({ link, canEdit }: { link: LinkItem; canEdit: boolean }) {
  const [state, action, pending] = useActionState<ActionState, FormData>(updateLinkAction.bind(null, link.id), {});
  const [clientErrors, setClientErrors] = useState<FieldErrors>({});
  const errors = { ...state.fieldErrors, ...clientErrors };
  const v = state.values ?? {};

  useEffect(() => {
    if (state.ok) toast.success("Cambios guardados");
    else if (state.error) toast.error(state.error);
  }, [state]);

  return (
    <form
      action={action}
      noValidate
      className="grid gap-4"
      onSubmit={(e) => {
        const fd = new FormData(e.currentTarget);
        const fe: FieldErrors = {};
        if (!String(fd.get("name") ?? "").trim()) fe.name = "Introduce un nombre.";
        const f = validateHttpUrl(String(fd.get("fallback_url") ?? ""), false);
        if (f) fe.fallback_url = f;
        setClientErrors(fe);
        if (Object.keys(fe).length) e.preventDefault();
      }}
    >
      <TextField name="name" label="Nombre" defaultValue={v.name ?? link.name} error={errors.name} required maxLength={120} disabled={!canEdit} />
      <TextField
        name="fallback_url"
        label="URL de respaldo"
        type="url"
        defaultValue={v.fallback_url ?? link.fallback_url ?? ""}
        error={errors.fallback_url}
        placeholder="https://ejemplo.com/no-disponible"
        hint="Vacío = página «no disponible» por defecto."
        disabled={!canEdit}
      />
      <WindowFields
        key={`${v.starts_at}|${v.expires_at}`}
        starts={"starts_at" in v ? v.starts_at : link.starts_at}
        expires={"expires_at" in v ? v.expires_at : link.expires_at}
        error={errors.window}
        disabled={!canEdit}
      />
      {state.error && !state.fieldErrors ? <FieldError id="edit-error" message={state.error} /> : null}
      {canEdit ? (
        <div>
          <Button type="submit" disabled={pending}>
            {pending ? "Guardando…" : "Guardar cambios"}
          </Button>
        </div>
      ) : null}
    </form>
  );
}
