"use client";

import { FileText, Monitor, Star, Sticker } from "lucide-react";
import { useId, useState } from "react";

import { Card, CardContent, CardDescription, CardHeader, CardTitle } from "@/components/ui/card";

import { DownloadMenu } from "./download-menu";

/** Plantillas de impresión (T033): la API las renderiza en SVG, PDF y PNG. */
export const TEMPLATES = [
  { id: "sticker", name: "Sticker", icon: Sticker, hint: "Pegatina con marco redondeado" },
  { id: "display", name: "Display", icon: Monitor, hint: "Para mostrador o tótem" },
  { id: "poster", name: "Póster A4", icon: FileText, hint: "Hoja completa para imprimir" },
  { id: "google_review", name: "Reseña en Google", icon: Star, hint: "Pide reseñas en tu perfil" },
] as const;

type TemplateId = (typeof TEMPLATES)[number]["id"];

/** Elige una plantilla (tarjetas seleccionables) y descarga con un único menú «Descargar». */
export function TemplatesGallery({ linkId, dirty }: { linkId: string; dirty?: boolean }) {
  const [selected, setSelected] = useState<TemplateId>("sticker");
  const name = useId();
  const current = TEMPLATES.find((t) => t.id === selected)!;
  return (
    <Card>
      <CardHeader>
        <CardTitle>Plantillas de impresión</CardTitle>
        <CardDescription>Elige cómo quieres imprimir tu QR y descárgalo ya maquetado.</CardDescription>
      </CardHeader>
      <CardContent className="grid gap-4">
        <div role="radiogroup" aria-label="Plantilla de impresión" className="grid grid-cols-1 gap-3 sm:grid-cols-2 xl:grid-cols-4">
          {TEMPLATES.map(({ id, name: label, icon: Icon, hint }) => (
            <label
              key={id}
              className="flex min-w-0 cursor-pointer flex-col items-center gap-1.5 rounded-lg border p-4 text-center transition-colors hover:bg-muted/50 has-[:checked]:border-primary has-[:checked]:bg-primary/5 has-[:checked]:ring-1 has-[:checked]:ring-primary has-[:focus-visible]:ring-2 has-[:focus-visible]:ring-ring"
            >
              <input
                type="radio" name={name} value={id} checked={selected === id}
                onChange={() => setSelected(id)} className="sr-only"
              />
              <Icon className="size-6 text-muted-foreground" aria-hidden="true" />
              <span className="text-sm font-medium">{label}</span>
              <span className="text-xs text-muted-foreground">{hint}</span>
            </label>
          ))}
        </div>
        <div className="flex flex-wrap items-center justify-between gap-3 rounded-lg bg-muted/50 px-4 py-3">
          <p className="text-sm">
            Plantilla: <span className="font-medium">{current.name}</span>
          </p>
          <DownloadMenu linkId={linkId} dirty={!!dirty} template={selected} />
        </div>
      </CardContent>
    </Card>
  );
}
