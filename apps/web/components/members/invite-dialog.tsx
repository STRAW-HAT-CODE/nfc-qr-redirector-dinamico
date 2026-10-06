"use client";

import { Loader2, UserPlus } from "lucide-react";
import { useState, useTransition } from "react";
import { toast } from "sonner";

import { addMemberAction } from "@/app/(app)/settings/members/actions";
import { Button } from "@/components/ui/button";
import {
  Dialog, DialogContent, DialogDescription, DialogFooter, DialogHeader, DialogTitle, DialogTrigger,
} from "@/components/ui/dialog";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from "@/components/ui/select";
import { Tooltip, TooltipContent, TooltipProvider, TooltipTrigger } from "@/components/ui/tooltip";
import type { Role } from "@/lib/api";
import { ROLE_LABEL, assignableRoles } from "./role-utils";

export function InviteDialog({ actor }: { actor: Role }) {
  const [open, setOpen] = useState(false);
  const [userId, setUserId] = useState("");
  const [role, setRole] = useState<Role>("viewer");
  const [error, setError] = useState<string>();
  const [pending, start] = useTransition();

  function submit(e: React.FormEvent) {
    e.preventDefault();
    setError(undefined);
    start(async () => {
      const res = await addMemberAction({ user_id: userId, role });
      if (res.ok) {
        toast.success(res.message);
        setOpen(false);
        setUserId("");
        setRole("viewer");
      } else {
        setError(res.message);
        toast.error(res.message);
      }
    });
  }

  return (
    <Dialog open={open} onOpenChange={setOpen}>
      <DialogTrigger asChild>
        <Button><UserPlus aria-hidden="true" />Añadir miembro</Button>
      </DialogTrigger>
      <DialogContent>
        <form onSubmit={submit} className="grid gap-4">
          <DialogHeader>
            <DialogTitle>Añadir miembro</DialogTitle>
            <DialogDescription>Indica el user_id (UUID) de un usuario existente.</DialogDescription>
          </DialogHeader>
          <div className="grid gap-2">
            <Label htmlFor="member-user-id">user_id</Label>
            <Input
              id="member-user-id" value={userId} onChange={(e) => setUserId(e.target.value)} required
              placeholder="00000000-0000-0000-0000-000000000000" autoComplete="off"
              aria-invalid={!!error} aria-describedby="member-err"
            />
            <p id="member-err" role="alert" className="text-sm text-destructive">{error}</p>
          </div>
          <div className="grid gap-2">
            <Label htmlFor="member-email">Email</Label>
            <TooltipProvider>
              <Tooltip>
                <TooltipTrigger asChild>
                  <span tabIndex={0} className="block">
                    <Input id="member-email" type="email" disabled placeholder="Invitación por email: próximamente" />
                  </span>
                </TooltipTrigger>
                <TooltipContent>Invitación por email: próximamente</TooltipContent>
              </Tooltip>
            </TooltipProvider>
          </div>
          <div className="grid gap-2">
            <Label htmlFor="member-role">Rol</Label>
            <Select value={role} onValueChange={(v) => setRole(v as Role)}>
              <SelectTrigger id="member-role"><SelectValue /></SelectTrigger>
              <SelectContent>
                {assignableRoles(actor).map((r) => <SelectItem key={r} value={r}>{ROLE_LABEL[r]}</SelectItem>)}
              </SelectContent>
            </Select>
          </div>
          <DialogFooter>
            <Button type="submit" disabled={pending || !userId.trim()}>
              {pending ? <Loader2 className="animate-spin" aria-hidden="true" /> : null}
              Añadir
            </Button>
          </DialogFooter>
        </form>
      </DialogContent>
    </Dialog>
  );
}
