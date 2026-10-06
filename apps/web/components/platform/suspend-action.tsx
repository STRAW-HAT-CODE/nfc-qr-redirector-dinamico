"use client";

import { Ban, RotateCcw } from "lucide-react";
import { useState, useTransition } from "react";
import { toast } from "sonner";

import { setLinkStatusAction, setOrgStatusAction, type PlatformResult } from "@/app/(platform)/platform/actions";
import { ConfirmDialog } from "@/components/platform/confirm-dialog";
import { Button } from "@/components/ui/button";

type Props =
  | { kind: "org"; id: string; name: string; suspended: boolean; onDone?: () => void }
  | { kind: "link"; id: string; name: string; suspended: boolean; onDone?: () => void };

/** Suspende/reactiva una org (status) o un enlace (paused), siempre con confirmación. */
export function SuspendAction(props: Props) {
  const { kind, id, name, suspended, onDone } = props;
  const [open, setOpen] = useState(false);
  const [pending, start] = useTransition();
  const noun = kind === "org" ? "organización" : "enlace";

  function run() {
    start(async () => {
      let res: PlatformResult;
      if (kind === "org") res = await setOrgStatusAction(id, suspended ? "active" : "suspended");
      else res = await setLinkStatusAction(id, suspended ? "active" : "paused");
      if (res.ok) {
        toast.success(res.message);
        setOpen(false);
        onDone?.();
      } else toast.error(res.message);
    });
  }

  return (
    <>
      <Button variant={suspended ? "outline" : "ghost"} size="sm" onClick={() => setOpen(true)}>
        {suspended ? <RotateCcw aria-hidden="true" /> : <Ban aria-hidden="true" />}
        {suspended ? "Reactivar" : "Suspender"}
        <span className="sr-only"> {noun} {name}</span>
      </Button>
      <ConfirmDialog
        open={open}
        onOpenChange={setOpen}
        title={suspended ? `¿Reactivar ${noun}?` : `¿Suspender ${noun}?`}
        description={
          suspended ? (
            <>«{name}» volverá a funcionar con normalidad.</>
          ) : kind === "org" ? (
            <>«{name}» quedará suspendida: sus enlaces dejarán de redirigir y sus miembros no podrán operar. La acción queda auditada.</>
          ) : (
            <>«{name}» dejará de redirigir (pausado) hasta que lo reactives. La acción queda auditada.</>
          )
        }
        confirmLabel={suspended ? "Reactivar" : "Suspender"}
        destructive={!suspended}
        pending={pending}
        onConfirm={run}
      />
    </>
  );
}
