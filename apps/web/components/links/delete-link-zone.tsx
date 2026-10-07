"use client";

import { Trash2 } from "lucide-react";
import { useRouter } from "next/navigation";
import { useState, useTransition } from "react";
import { toast } from "sonner";

import { deleteLinkPermanentAction } from "@/app/(app)/links/actions";
import {
  AlertDialog,
  AlertDialogCancel,
  AlertDialogContent,
  AlertDialogDescription,
  AlertDialogFooter,
  AlertDialogHeader,
  AlertDialogTitle,
  AlertDialogTrigger,
} from "@/components/ui/alert-dialog";
import { Button } from "@/components/ui/button";
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";

/** Zona de peligro: eliminación definitiva (solo admin+; el padre decide si se renderiza). */
export function DeleteLinkZone({ linkId, linkName }: { linkId: string; linkName: string }) {
  const router = useRouter();
  const [open, setOpen] = useState(false);
  const [typed, setTyped] = useState("");
  const [pending, start] = useTransition();
  const matches = typed === linkName;

  function confirm() {
    if (!matches) return;
    start(async () => {
      const res = await deleteLinkPermanentAction(linkId);
      if (res.error) {
        toast.error(res.error);
        return;
      }
      toast.success("Enlace eliminado");
      setOpen(false);
      router.replace("/links");
    });
  }

  return (
    <Card className="border-destructive/40 lg:col-span-2">
      <CardHeader>
        <CardTitle className="text-destructive">Peligro</CardTitle>
      </CardHeader>
      <CardContent className="flex flex-wrap items-center justify-between gap-3">
        <p className="min-w-0 flex-1 text-sm text-muted-foreground">
          Elimina el enlace, su diseño, logo, tags NFC, historial y métricas. No se puede deshacer.
        </p>
        <AlertDialog
          open={open}
          onOpenChange={(o) => {
            if (pending) return;
            setOpen(o);
            if (!o) setTyped("");
          }}
        >
          <AlertDialogTrigger asChild>
            <Button type="button" variant="destructive">
              <Trash2 />
              Eliminar definitivamente
            </Button>
          </AlertDialogTrigger>
          <AlertDialogContent>
            <AlertDialogHeader>
              <AlertDialogTitle>¿Eliminar definitivamente este enlace?</AlertDialogTitle>
              <AlertDialogDescription>
                Los QR y NFC impresos dejarán de funcionar para siempre. Se borran el diseño, el logo, los tags NFC, el
                historial y las métricas. No se puede deshacer.
              </AlertDialogDescription>
            </AlertDialogHeader>
            <form
              className="grid gap-2"
              onSubmit={(e) => {
                e.preventDefault();
                confirm();
              }}
            >
              <Label htmlFor="confirm-link-name">
                Escribe <strong className="break-all">{linkName}</strong> para confirmar
              </Label>
              <Input
                id="confirm-link-name"
                value={typed}
                onChange={(e) => setTyped(e.target.value)}
                autoComplete="off"
                disabled={pending}
              />
            </form>
            <AlertDialogFooter>
              <AlertDialogCancel disabled={pending}>Cancelar</AlertDialogCancel>
              <Button type="button" variant="destructive" disabled={!matches || pending} onClick={confirm}>
                {pending ? "Eliminando…" : "Eliminar definitivamente"}
              </Button>
            </AlertDialogFooter>
          </AlertDialogContent>
        </AlertDialog>
      </CardContent>
    </Card>
  );
}
