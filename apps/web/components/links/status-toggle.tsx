"use client";

import { Archive, Pause, Play } from "lucide-react";
import { useTransition } from "react";
import { toast } from "sonner";

import { setStatusAction } from "@/app/(app)/links/actions";
import {
  AlertDialog,
  AlertDialogAction,
  AlertDialogCancel,
  AlertDialogContent,
  AlertDialogDescription,
  AlertDialogFooter,
  AlertDialogHeader,
  AlertDialogTitle,
  AlertDialogTrigger,
} from "@/components/ui/alert-dialog";
import { Button } from "@/components/ui/button";

import type { LinkStatus } from "./types";

export function StatusToggle({
  linkId,
  status,
  canEdit,
  canArchive,
}: {
  linkId: string;
  status: LinkStatus;
  canEdit: boolean;
  canArchive: boolean;
}) {
  const [pending, start] = useTransition();

  function change(next: LinkStatus, okMsg: string) {
    start(async () => {
      const res = await setStatusAction(linkId, next);
      if (res.error) toast.error(res.error);
      else toast.success(okMsg);
    });
  }

  if (status === "archived") {
    return <p className="text-sm text-muted-foreground">Este enlace está archivado y ya no redirige.</p>;
  }
  const paused = status === "paused";
  return (
    <div className="flex flex-wrap gap-2">
      <Button
        type="button"
        variant="secondary"
        disabled={!canEdit || pending}
        onClick={() => change(paused ? "active" : "paused", paused ? "Enlace activado" : "Enlace pausado")}
      >
        {paused ? <Play /> : <Pause />}
        {paused ? "Activar" : "Pausar"}
      </Button>
      {canArchive ? (
        <AlertDialog>
          <AlertDialogTrigger asChild>
            <Button type="button" variant="outline" disabled={pending}>
              <Archive />
              Archivar
            </Button>
          </AlertDialogTrigger>
          <AlertDialogContent>
            <AlertDialogHeader>
              <AlertDialogTitle>¿Archivar este enlace?</AlertDialogTitle>
              <AlertDialogDescription>
                Dejará de redirigir y los QR impresos no funcionarán. Esta acción solo puede revertirla soporte.
              </AlertDialogDescription>
            </AlertDialogHeader>
            <AlertDialogFooter>
              <AlertDialogCancel>Cancelar</AlertDialogCancel>
              <AlertDialogAction onClick={() => change("archived", "Enlace archivado")}>Archivar</AlertDialogAction>
            </AlertDialogFooter>
          </AlertDialogContent>
        </AlertDialog>
      ) : null}
      {!canEdit ? <p className="w-full text-xs text-muted-foreground">Necesitas rol editor para cambiar el estado.</p> : null}
    </div>
  );
}
