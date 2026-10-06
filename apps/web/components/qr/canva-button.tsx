"use client";

import { Palette } from "lucide-react";
import { toast } from "sonner";

import { Button } from "@/components/ui/button";

import { qrUrl } from "./download-menu";

/** Sin integración de API (ADR-0005): descarga el SVG y abre Canva para importarlo. */
export function CanvaButton({ linkId }: { linkId: string }) {
  function go() {
    window.open("https://www.canva.com/", "_blank", "noopener,noreferrer");
    const a = document.createElement("a");
    a.href = qrUrl(linkId, "svg");
    a.download = "";
    document.body.appendChild(a);
    a.click();
    a.remove();
    toast.info("SVG descargado. En Canva: Subir archivos → elige el SVG → arrástralo a tu diseño.");
  }
  return (
    <div className="grid gap-1.5">
      <Button type="button" variant="outline" onClick={go}>
        <Palette aria-hidden="true" /> Terminar en Canva
      </Button>
      <p className="text-xs text-muted-foreground">Descarga el SVG y abre Canva en otra pestaña para importarlo.</p>
    </div>
  );
}
