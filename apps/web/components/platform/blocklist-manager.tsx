"use client";

import { ShieldBan, Trash2 } from "lucide-react";
import { useState, useTransition } from "react";
import { toast } from "sonner";

import { blockDomainAction, unblockDomainAction } from "@/app/(platform)/platform/actions";
import { EmptyState } from "@/components/empty-state";
import { ConfirmDialog } from "@/components/platform/confirm-dialog";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from "@/components/ui/table";
import type { BlockedDomain } from "@/lib/api";

const dateFmt = new Intl.DateTimeFormat("es", { dateStyle: "medium" });

export function BlocklistManager({ domains }: { domains: BlockedDomain[] }) {
  const [value, setValue] = useState("");
  const [toBlock, setToBlock] = useState<string | null>(null);
  const [toUnblock, setToUnblock] = useState<string | null>(null);
  const [pending, start] = useTransition();

  function submitBlock() {
    if (!toBlock) return;
    start(async () => {
      const res = await blockDomainAction(toBlock);
      if (res.ok) {
        toast.success(res.message);
        setToBlock(null);
        setValue("");
      } else toast.error(res.message);
    });
  }

  function submitUnblock() {
    if (!toUnblock) return;
    start(async () => {
      const res = await unblockDomainAction(toUnblock);
      if (res.ok) {
        toast.success(res.message);
        setToUnblock(null);
      } else toast.error(res.message);
    });
  }

  return (
    <div className="grid gap-4">
      <form
        className="flex flex-col gap-2 sm:flex-row sm:items-end"
        onSubmit={(e) => {
          e.preventDefault();
          if (value.trim()) setToBlock(value.trim().toLowerCase());
        }}
      >
        <div className="grid flex-1 gap-2">
          <Label htmlFor="block-domain">Bloquear dominio de destino</Label>
          <Input id="block-domain" value={value} onChange={(e) => setValue(e.target.value)} placeholder="malo.example" maxLength={253} autoComplete="off" />
        </div>
        <Button type="submit" disabled={!value.trim()}>
          <ShieldBan aria-hidden="true" />
          Bloquear
        </Button>
      </form>

      {domains.length === 0 ? (
        <EmptyState icon={<ShieldBan />} title="Sin dominios bloqueados" description="Los enlaces no podrán apuntar a los dominios que bloquees aquí." />
      ) : (
        <div className="rounded-xl border">
          <Table>
            <TableHeader>
              <TableRow>
                <TableHead>Dominio</TableHead>
                <TableHead className="hidden sm:table-cell">Desde</TableHead>
                <TableHead className="w-12"><span className="sr-only">Acciones</span></TableHead>
              </TableRow>
            </TableHeader>
            <TableBody>
              {domains.map((d) => (
                <TableRow key={d.domain}>
                  <TableCell className="font-mono text-sm">{d.domain}</TableCell>
                  <TableCell className="hidden text-muted-foreground sm:table-cell">{dateFmt.format(new Date(d.created_at))}</TableCell>
                  <TableCell>
                    <Button variant="ghost" size="icon" onClick={() => setToUnblock(d.domain)} aria-label={`Desbloquear ${d.domain}`}>
                      <Trash2 aria-hidden="true" />
                    </Button>
                  </TableCell>
                </TableRow>
              ))}
            </TableBody>
          </Table>
        </div>
      )}

      <ConfirmDialog
        open={toBlock !== null}
        onOpenChange={(o) => !o && setToBlock(null)}
        title="¿Bloquear dominio?"
        description={<><span className="font-mono">{toBlock}</span> no se podrá usar como destino de enlaces nuevos o editados.</>}
        confirmLabel="Bloquear"
        pending={pending}
        onConfirm={submitBlock}
      />
      <ConfirmDialog
        open={toUnblock !== null}
        onOpenChange={(o) => !o && setToUnblock(null)}
        title="¿Desbloquear dominio?"
        description={<><span className="font-mono">{toUnblock}</span> volverá a poder usarse como destino.</>}
        confirmLabel="Desbloquear"
        destructive={false}
        pending={pending}
        onConfirm={submitUnblock}
      />
    </div>
  );
}
