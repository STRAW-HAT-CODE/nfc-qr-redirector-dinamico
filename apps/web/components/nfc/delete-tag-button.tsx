"use client";

import { Loader2, Trash2 } from "lucide-react";
import { useState, useTransition } from "react";
import { toast } from "sonner";

import { deleteTagAction } from "@/app/(app)/links/[id]/nfc/actions";
import { Button } from "@/components/ui/button";
import {
  Dialog, DialogContent, DialogDescription, DialogFooter, DialogHeader, DialogTitle,
} from "@/components/ui/dialog";
import type { NfcTag } from "./types";

export function DeleteTagButton({ linkId, tag }: { linkId: string; tag: NfcTag }) {
  const [open, setOpen] = useState(false);
  const [pending, start] = useTransition();

  function confirm() {
    start(async () => {
      const res = await deleteTagAction(linkId, tag.id);
      if (res.ok) {
        toast.success(res.message);
        setOpen(false);
      } else toast.error(res.message);
    });
  }

  return (
    <>
      <Button
        variant="ghost" size="icon" onClick={() => setOpen(true)}
        aria-label={`Eliminar ${tag.label}`} title="Eliminar"
      >
        <Trash2 />
      </Button>
      <Dialog open={open} onOpenChange={setOpen}>
        <DialogContent>
          <DialogHeader>
            <DialogTitle>¿Eliminar «{tag.label}»?</DialogTitle>
            <DialogDescription>
              Los escaneos ya registrados se conservan, pero sin etiqueta. Un chip grabado con esta URL seguirá
              abriendo el enlace como canal nfc, sin ubicación.
            </DialogDescription>
          </DialogHeader>
          <DialogFooter>
            <Button variant="outline" onClick={() => setOpen(false)} disabled={pending}>Cancelar</Button>
            <Button variant="destructive" onClick={confirm} disabled={pending}>
              {pending ? <Loader2 className="animate-spin" aria-hidden="true" /> : null}
              Eliminar
            </Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>
    </>
  );
}
