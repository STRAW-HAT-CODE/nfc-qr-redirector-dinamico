"use client";

import { Loader2, Plus } from "lucide-react";
import { useActionState, useState } from "react";

import { createOrgAction, type CreateOrgState } from "@/app/(app)/orgs/actions";
import { Alert, AlertDescription } from "@/components/ui/alert";
import { Button } from "@/components/ui/button";
import { Dialog, DialogContent, DialogDescription, DialogHeader, DialogTitle, DialogTrigger } from "@/components/ui/dialog";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";

const slugify = (v: string) =>
  v.toLowerCase().normalize("NFD").replace(/[̀-ͯ]/g, "").replace(/[^a-z0-9]+/g, "-").replace(/^-+|-+$/g, "").slice(0, 63);

const initial: CreateOrgState = {};

export function CreateOrgDialog({ label = "Crear organización" }: { label?: string }) {
  const [state, action, pending] = useActionState(createOrgAction, initial);
  const [slug, setSlug] = useState("");
  const [touched, setTouched] = useState(false);

  return (
    <Dialog>
      <DialogTrigger asChild>
        <Button><Plus aria-hidden="true" />{label}</Button>
      </DialogTrigger>
      <DialogContent>
        <DialogHeader>
          <DialogTitle>Nueva organización</DialogTitle>
          <DialogDescription>Serás el propietario. Podrás invitar miembros después.</DialogDescription>
        </DialogHeader>
        <form action={action} className="grid gap-4">
          {state.error ? <Alert variant="destructive"><AlertDescription>{state.error}</AlertDescription></Alert> : null}
          <div className="grid gap-2">
            <Label htmlFor="org-name">Nombre</Label>
            <Input
              id="org-name" name="name" required maxLength={120}
              aria-invalid={!!state.fieldErrors?.name} aria-describedby="org-name-err"
              onChange={(e) => { if (!touched) setSlug(slugify(e.target.value)); }}
            />
            <p id="org-name-err" className="text-sm text-destructive">{state.fieldErrors?.name}</p>
          </div>
          <div className="grid gap-2">
            <Label htmlFor="org-slug">Identificador (slug)</Label>
            <Input
              id="org-slug" name="slug" required value={slug}
              onChange={(e) => { setTouched(true); setSlug(e.target.value); }}
              aria-invalid={!!state.fieldErrors?.slug} aria-describedby="org-slug-err"
            />
            <p id="org-slug-err" className="text-sm text-destructive">{state.fieldErrors?.slug}</p>
          </div>
          <Button type="submit" disabled={pending}>
            {pending ? <Loader2 className="animate-spin" aria-hidden="true" /> : null}
            Crear
          </Button>
        </form>
      </DialogContent>
    </Dialog>
  );
}
