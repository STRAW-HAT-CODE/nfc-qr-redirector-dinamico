"use client";

import { Loader2, Pencil, Plus } from "lucide-react";
import { useState, useTransition } from "react";
import { toast } from "sonner";

import { createTagAction, updateTagAction } from "@/app/(app)/links/[id]/nfc/actions";
import { Button } from "@/components/ui/button";
import {
  Dialog, DialogContent, DialogDescription, DialogFooter, DialogHeader, DialogTitle, DialogTrigger,
} from "@/components/ui/dialog";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import type { NfcTag } from "./types";

/** Crear (sin `tag`) o editar (con `tag`) una etiqueta. Solo se muestra a editor+. */
export function TagDialog({ linkId, tag }: { linkId: string; tag?: NfcTag }) {
  const [open, setOpen] = useState(false);
  const [label, setLabel] = useState(tag?.label ?? "");
  const [location, setLocation] = useState(tag?.location ?? "");
  const [uid, setUid] = useState(tag?.uid ?? "");
  const [error, setError] = useState<string>();
  const [pending, start] = useTransition();
  const editing = !!tag;

  function onOpenChange(next: boolean) {
    setOpen(next);
    if (next) {
      setLabel(tag?.label ?? "");
      setLocation(tag?.location ?? "");
      setUid(tag?.uid ?? "");
      setError(undefined);
    }
  }

  function submit(e: React.FormEvent) {
    e.preventDefault();
    setError(undefined);
    start(async () => {
      const v = { label, location, uid };
      const res = tag ? await updateTagAction(linkId, tag.id, v) : await createTagAction(linkId, v);
      if (res.ok) {
        toast.success(res.message);
        setOpen(false);
      } else {
        setError(res.message);
      }
    });
  }

  const p = editing ? `tag-${tag.id}` : "tag-new";
  return (
    <Dialog open={open} onOpenChange={onOpenChange}>
      <DialogTrigger asChild>
        {editing ? (
          <Button variant="ghost" size="icon" aria-label={`Editar ${tag.label}`} title="Editar">
            <Pencil />
          </Button>
        ) : (
          <Button>
            <Plus aria-hidden="true" /> Nueva etiqueta
          </Button>
        )}
      </DialogTrigger>
      <DialogContent>
        <form onSubmit={submit} className="grid gap-4">
          <DialogHeader>
            <DialogTitle>{editing ? "Editar etiqueta" : "Nueva etiqueta NFC"}</DialogTitle>
            <DialogDescription>
              El UID es opcional y evita registrar dos veces el mismo chip (se ve en NFC Tools → Leer).
            </DialogDescription>
          </DialogHeader>
          <div className="grid gap-2">
            <Label htmlFor={`${p}-label`}>Nombre</Label>
            <Input id={`${p}-label`} value={label} onChange={(e) => setLabel(e.target.value)} required maxLength={80} />
          </div>
          <div className="grid gap-2">
            <Label htmlFor={`${p}-loc`}>Ubicación</Label>
            <Input
              id={`${p}-loc`} value={location} onChange={(e) => setLocation(e.target.value)}
              maxLength={120} placeholder="Ej. Mostrador, Mesa 4" 
            />
          </div>
          <div className="grid gap-2">
            <Label htmlFor={`${p}-uid`}>UID del chip</Label>
            <Input
              id={`${p}-uid`} value={uid} onChange={(e) => setUid(e.target.value)} maxLength={40}
              placeholder="04:A2:5B:1C:2D:3E:4F" autoComplete="off" className="font-mono"
              aria-invalid={!!error} aria-describedby={`${p}-err`}
            />
            <p id={`${p}-err`} role="alert" className="text-sm text-destructive">{error}</p>
          </div>
          <DialogFooter>
            <Button type="submit" disabled={pending || !label.trim()}>
              {pending ? <Loader2 className="animate-spin" aria-hidden="true" /> : null}
              {editing ? "Guardar" : "Crear"}
            </Button>
          </DialogFooter>
        </form>
      </DialogContent>
    </Dialog>
  );
}
