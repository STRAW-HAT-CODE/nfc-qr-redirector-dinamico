"use client";

import { Check, Loader2 } from "lucide-react";
/* eslint-disable @next/next/no-img-element */

import { Button } from "@/components/ui/button";
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from "@/components/ui/card";

/** «Diseños rápidos» (T060): presets de un clic. Solo editor+ los aplica. */
export function QuickDesigns({
  active, onApply, onRemove, disabled, busy,
}: { active: boolean; onApply: () => void; onRemove: () => void; disabled?: boolean; busy?: boolean }) {
  return (
    <Card>
      <CardHeader>
        <CardTitle>Diseños rápidos</CardTitle>
        <CardDescription>Aplica un diseño listo con un clic.</CardDescription>
      </CardHeader>
      <CardContent className="grid gap-3">
        <div className={`flex items-center gap-4 rounded-lg border p-3 ${active ? "border-primary ring-1 ring-primary" : ""}`}>
          <div className="flex size-16 shrink-0 items-center justify-center rounded-md border bg-white">
            <img src="/presets/google-g.svg" alt="" className="size-9" width={36} height={36} />
          </div>
          <div className="min-w-0 flex-1">
            <p className="text-sm font-medium">Reseñas de Google</p>
            <p className="text-xs text-muted-foreground">QR negro con la «G» de Google al centro (corrección H).</p>
          </div>
          {active ? (
            <Button variant="outline" size="sm" onClick={onRemove} disabled={disabled || busy} aria-pressed="true">
              {busy ? <Loader2 className="animate-spin" /> : <Check />} Quitar
            </Button>
          ) : (
            <Button size="sm" onClick={onApply} disabled={disabled || busy}>
              {busy ? <Loader2 className="animate-spin" /> : null} Aplicar
            </Button>
          )}
        </div>
        <p className="text-xs text-muted-foreground">Usa este diseño solo para enlazar a tu perfil de Google Business (reseñas).</p>
      </CardContent>
    </Card>
  );
}
