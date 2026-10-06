"use client";

import { useActionState, useEffect, useRef, useState } from "react";
import { toast } from "sonner";

import { updateDestinationAction } from "@/app/(app)/links/actions";
import {
  AlertDialog,
  AlertDialogAction,
  AlertDialogCancel,
  AlertDialogContent,
  AlertDialogDescription,
  AlertDialogFooter,
  AlertDialogHeader,
  AlertDialogTitle,
} from "@/components/ui/alert-dialog";
import { Button } from "@/components/ui/button";

import { TextField } from "./link-fields";
import { validateHttpUrl, type ActionState } from "./types";

export function DestinationEditor({ linkId, current, canEdit }: { linkId: string; current: string; canEdit: boolean }) {
  const [state, action, pending] = useActionState<ActionState, FormData>(updateDestinationAction.bind(null, linkId), {});
  const [open, setOpen] = useState(false);
  const [clientError, setClientError] = useState<string>();
  const formRef = useRef<HTMLFormElement>(null);
  const confirmed = useRef(false);

  useEffect(() => {
    if (state.ok) toast.success("Destino actualizado");
    else if (state.error) toast.error(state.error);
  }, [state]);

  const error = clientError ?? state.fieldErrors?.destination_url;

  function askConfirm() {
    const value = String(new FormData(formRef.current!).get("destination_url") ?? "");
    const err = validateHttpUrl(value, true);
    setClientError(err);
    if (err) return;
    if (value.trim() === current) {
      setClientError("Es el mismo destino actual.");
      return;
    }
    setOpen(true);
  }

  return (
    <>
      <form ref={formRef} action={action} noValidate className="grid gap-3" onSubmit={(e) => {
          if (confirmed.current) {
            confirmed.current = false;
            return; // confirmado: deja que corra la Server Action
          }
          e.preventDefault();
          askConfirm();
        }}>
        <TextField
          name="destination_url"
          label="URL de destino"
          type="url"
          defaultValue={state.values?.destination_url ?? current}
          error={error}
          disabled={!canEdit}
          required
        />
        {canEdit ? (
          <div>
            <Button type="submit" variant="secondary" disabled={pending}>
              {pending ? "Guardando…" : "Cambiar destino"}
            </Button>
          </div>
        ) : (
          <p className="text-xs text-muted-foreground">Necesitas rol editor o superior para cambiar el destino.</p>
        )}
      </form>
      <AlertDialog open={open} onOpenChange={setOpen}>
        <AlertDialogContent>
          <AlertDialogHeader>
            <AlertDialogTitle>¿Cambiar el destino?</AlertDialogTitle>
            <AlertDialogDescription>
              Todos los QR y tags NFC ya impresos o escritos con este enlace llevarán a la nueva URL desde ahora. El cambio
              queda en el historial.
            </AlertDialogDescription>
          </AlertDialogHeader>
          <AlertDialogFooter>
            <AlertDialogCancel>Cancelar</AlertDialogCancel>
            <AlertDialogAction
              onClick={() => {
                confirmed.current = true;
                formRef.current?.requestSubmit();
              }}
            >
              Sí, cambiar destino
            </AlertDialogAction>
          </AlertDialogFooter>
        </AlertDialogContent>
      </AlertDialog>
    </>
  );
}
