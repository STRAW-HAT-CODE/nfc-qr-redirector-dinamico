"use client";

import { Loader2, Trash2 } from "lucide-react";
import { useState, useTransition } from "react";
import { toast } from "sonner";

import { changeRoleAction, removeMemberAction } from "@/app/(app)/settings/members/actions";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import {
  Dialog, DialogContent, DialogDescription, DialogFooter, DialogHeader, DialogTitle,
} from "@/components/ui/dialog";
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from "@/components/ui/select";
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from "@/components/ui/table";
import type { Member, Role } from "@/lib/api";
import { ALL_ROLES, ROLE_LABEL, assignableRoles, canManage } from "./role-utils";

const dateFmt = new Intl.DateTimeFormat("es", { dateStyle: "medium" });

function RoleCell({ member, actor, disabled }: { member: Member; actor: Role; disabled: boolean }) {
  const [pending, start] = useTransition();
  const [value, setValue] = useState<Role>(member.role);
  const allowed = assignableRoles(actor);

  if (disabled) return <Badge variant="secondary">{ROLE_LABEL[member.role]}</Badge>;

  return (
    <div className="flex items-center gap-2">
      <Select
        value={value}
        disabled={pending}
        onValueChange={(next) => {
          const prev = value;
          setValue(next as Role);
          start(async () => {
            const res = await changeRoleAction(member.user_id, next as Role);
            if (res.ok) toast.success(res.message);
            else {
              setValue(prev);
              toast.error(res.message);
            }
          });
        }}
      >
        <SelectTrigger className="w-32" aria-label="Rol del miembro">
          <SelectValue />
        </SelectTrigger>
        <SelectContent>
          {ALL_ROLES.map((r) => (
            <SelectItem key={r} value={r} disabled={!allowed.includes(r)}>
              {ROLE_LABEL[r]}
            </SelectItem>
          ))}
        </SelectContent>
      </Select>
      {pending ? <Loader2 className="size-4 animate-spin text-muted-foreground" aria-label="Guardando" /> : null}
    </div>
  );
}

function RemoveButton({ member }: { member: Member }) {
  const [open, setOpen] = useState(false);
  const [pending, start] = useTransition();

  return (
    <>
      <Button variant="ghost" size="icon" onClick={() => setOpen(true)} aria-label={`Quitar miembro ${member.user_id}`}>
        <Trash2 aria-hidden="true" />
      </Button>
      <Dialog open={open} onOpenChange={(o) => !pending && setOpen(o)}>
        <DialogContent>
          <DialogHeader>
            <DialogTitle>¿Quitar miembro?</DialogTitle>
            <DialogDescription>
              <span className="break-all font-mono text-xs">{member.user_id}</span> perderá el acceso a esta organización.
            </DialogDescription>
          </DialogHeader>
          <DialogFooter>
            <Button variant="outline" onClick={() => setOpen(false)} disabled={pending}>Cancelar</Button>
            <Button
              variant="destructive"
              disabled={pending}
              onClick={() =>
                start(async () => {
                  const res = await removeMemberAction(member.user_id);
                  if (res.ok) {
                    toast.success(res.message);
                    setOpen(false);
                  } else toast.error(res.message);
                })
              }
            >
              {pending ? <Loader2 className="animate-spin" aria-hidden="true" /> : null}
              Quitar
            </Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>
    </>
  );
}

export function MembersTable({ members, actor, currentUserId }: { members: Member[]; actor: Role; currentUserId: string }) {
  return (
    <div className="rounded-xl border">
      <Table>
        <TableHeader>
          <TableRow>
            <TableHead>Usuario</TableHead>
            <TableHead>Rol</TableHead>
            <TableHead className="hidden sm:table-cell">Desde</TableHead>
            <TableHead className="w-12"><span className="sr-only">Acciones</span></TableHead>
          </TableRow>
        </TableHeader>
        <TableBody>
          {members.map((m) => {
            const manageable = canManage(actor, m.role);
            return (
              <TableRow key={m.user_id}>
                <TableCell>
                  <span className="break-all font-mono text-xs">{m.user_id}</span>
                  {m.user_id === currentUserId ? <Badge variant="outline" className="ml-2">Tú</Badge> : null}
                </TableCell>
                <TableCell><RoleCell member={m} actor={actor} disabled={!manageable} /></TableCell>
                <TableCell className="hidden text-muted-foreground sm:table-cell">{dateFmt.format(new Date(m.created_at))}</TableCell>
                <TableCell>{manageable ? <RemoveButton member={m} /> : null}</TableCell>
              </TableRow>
            );
          })}
        </TableBody>
      </Table>
    </div>
  );
}
