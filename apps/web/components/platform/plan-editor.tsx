"use client";

import { Loader2, SlidersHorizontal } from "lucide-react";
import { useState, useTransition } from "react";
import { toast } from "sonner";

import { parseLimits, updateOrgPlanAction } from "@/app/(platform)/platform/actions";
import { Button } from "@/components/ui/button";
import {
  Dialog, DialogContent, DialogDescription, DialogFooter, DialogHeader, DialogTitle,
} from "@/components/ui/dialog";
import { Label } from "@/components/ui/label";
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from "@/components/ui/select";
import type { AdminOrg } from "@/lib/api";

export const PLANS = ["free", "pro", "business"] as const;

export function PlanEditor({ org }: { org: AdminOrg }) {
  const [open, setOpen] = useState(false);
  const [plan, setPlan] = useState(org.plan);
  const [json, setJson] = useState(JSON.stringify(org.limits ?? {}, null, 2));
  const [error, setError] = useState<string | null>(null);
  const [pending, start] = useTransition();
  const plans = PLANS.includes(org.plan as (typeof PLANS)[number]) ? PLANS : [...PLANS, org.plan];

  function reset(next: boolean) {
    if (next) {
      setPlan(org.plan);
      setJson(JSON.stringify(org.limits ?? {}, null, 2));
      setError(null);
    }
    setOpen(next);
  }

  async function validate(value: string) {
    const r = await parseLimits(value);
    setError(r.ok ? null : r.message);
    return r.ok;
  }

  function save() {
    start(async () => {
      if (!(await validate(json))) return;
      const res = await updateOrgPlanAction(org.id, plan, json);
      if (res.ok) {
        toast.success(res.message);
        setOpen(false);
      } else setError(res.message ?? "No se pudo guardar.");
    });
  }

  return (
    <>
      <Button variant="ghost" size="sm" onClick={() => reset(true)}>
        <SlidersHorizontal aria-hidden="true" />
        Plan
        <span className="sr-only"> de {org.name}</span>
      </Button>
      <Dialog open={open} onOpenChange={(o) => !pending && reset(o)}>
        <DialogContent>
          <DialogHeader>
            <DialogTitle>Plan y límites · {org.name}</DialogTitle>
            <DialogDescription>
              Los overrides sustituyen los límites del plan. Claves: max_links, max_members, max_nfc_tags, max_logos,
              scans_retention_days (entero ≥ 0 o null). Vacío <code>{"{}"}</code> = usar los del plan.
            </DialogDescription>
          </DialogHeader>
          <div className="grid gap-4">
            <div className="grid gap-2">
              <Label htmlFor={`plan-${org.id}`}>Plan</Label>
              <Select value={plan} onValueChange={setPlan}>
                <SelectTrigger id={`plan-${org.id}`} className="w-full"><SelectValue /></SelectTrigger>
                <SelectContent>
                  {plans.map((p) => <SelectItem key={p} value={p} className="capitalize">{p}</SelectItem>)}
                </SelectContent>
              </Select>
            </div>
            <div className="grid gap-2">
              <Label htmlFor={`limits-${org.id}`}>Overrides de límites (JSON)</Label>
              <textarea
                id={`limits-${org.id}`}
                value={json}
                rows={7}
                spellCheck={false}
                onChange={(e) => { setJson(e.target.value); if (error) void validate(e.target.value); }}
                onBlur={(e) => void validate(e.target.value)}
                aria-invalid={error ? true : undefined}
                aria-describedby={error ? `limits-err-${org.id}` : undefined}
                className="rounded-md border bg-transparent p-2 font-mono text-xs focus-visible:outline-2 focus-visible:outline-ring aria-invalid:border-destructive"
              />
              {error ? <p id={`limits-err-${org.id}`} role="alert" className="text-sm text-destructive">{error}</p> : null}
            </div>
          </div>
          <DialogFooter>
            <Button variant="outline" onClick={() => setOpen(false)} disabled={pending}>Cancelar</Button>
            <Button onClick={save} disabled={pending || !!error}>
              {pending ? <Loader2 className="animate-spin" aria-hidden="true" /> : null}
              Guardar
            </Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>
    </>
  );
}
