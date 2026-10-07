"use client";

import { ChevronDown, Download, FileText, Monitor, Star, Sticker } from "lucide-react";

import { Button } from "@/components/ui/button";
import { DropdownMenu, DropdownMenuContent, DropdownMenuItem, DropdownMenuTrigger } from "@/components/ui/dropdown-menu";
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from "@/components/ui/card";

import { qrUrl } from "./download-menu";

/** Plantillas de impresión (T033): la API las renderiza en SVG, PDF y PNG. */
export const TEMPLATES = [
  { id: "sticker", name: "Sticker", icon: Sticker, hint: "Pegatina con marco redondeado" },
  { id: "display", name: "Display", icon: Monitor, hint: "Para mostrador o tótem" },
  { id: "poster", name: "Póster A4", icon: FileText, hint: "Hoja completa para imprimir" },
  { id: "google_review", name: "Reseña en Google", icon: Star, hint: "Pide reseñas en tu perfil" },
] as const;

export function TemplatesGallery({ linkId, dirty }: { linkId: string; dirty?: boolean }) {
  return (
    <Card>
      <CardHeader>
        <CardTitle>Plantillas de impresión</CardTitle>
        <CardDescription>
          Descarga el QR ya maquetado para imprimir. {dirty ? "Guarda el diseño para incluir los cambios." : "Usa el diseño guardado."}
        </CardDescription>
      </CardHeader>
      <CardContent>
        <ul className="grid grid-cols-1 gap-3 sm:grid-cols-2 xl:grid-cols-4">
          {TEMPLATES.map(({ id, name, icon: Icon, hint }) => (
            <li key={id} className="flex min-w-0 flex-col items-center gap-2 rounded-lg border p-4 text-center">
              <Icon className="size-6 text-muted-foreground" aria-hidden="true" />
              <span className="text-sm font-medium">{name}</span>
              <span className="text-xs text-muted-foreground">{hint}</span>
              <DropdownMenu>
                <DropdownMenuTrigger asChild>
                  <Button variant="outline" size="sm" className="mt-auto w-full" aria-label={`Descargar plantilla ${name}`}>
                    <Download aria-hidden="true" /> Descargar <ChevronDown aria-hidden="true" />
                  </Button>
                </DropdownMenuTrigger>
                <DropdownMenuContent align="center">
                  {(["svg", "pdf", "png"] as const).map((f) => (
                    <DropdownMenuItem key={f} asChild>
                      <a href={qrUrl(linkId, f, { template: id })} download>
                        <Download aria-hidden="true" /> {f.toUpperCase()}
                      </a>
                    </DropdownMenuItem>
                  ))}
                </DropdownMenuContent>
              </DropdownMenu>
            </li>
          ))}
        </ul>
      </CardContent>
    </Card>
  );
}
