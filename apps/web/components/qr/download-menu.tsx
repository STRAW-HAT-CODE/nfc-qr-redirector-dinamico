"use client";

import { ChevronDown, Download } from "lucide-react";

import { Button } from "@/components/ui/button";
import {
  DropdownMenu, DropdownMenuContent, DropdownMenuItem, DropdownMenuLabel, DropdownMenuSeparator, DropdownMenuTrigger,
} from "@/components/ui/dropdown-menu";

export const PNG_SIZES = [512, 1024, 2048] as const;

/** URL del proxy de descarga (el token queda en el servidor). `template` listo para T033. */
export function qrUrl(linkId: string, format: "png" | "svg" | "pdf", opts: { size?: number; template?: string } = {}) {
  const sp = new URLSearchParams();
  if (opts.size) sp.set("size", String(opts.size));
  if (opts.template && opts.template !== "none") sp.set("template", opts.template);
  const q = sp.toString();
  return `/api/qr/${linkId}/${format}${q ? `?${q}` : ""}`;
}

export function DownloadMenu({ linkId, dirty, template }: { linkId: string; dirty: boolean; template?: string }) {
  const item = (href: string, label: string) => (
    <DropdownMenuItem key={href} asChild>
      <a href={href} download>
        <Download aria-hidden="true" /> {label}
      </a>
    </DropdownMenuItem>
  );
  return (
    <DropdownMenu>
      <DropdownMenuTrigger asChild>
        <Button variant="outline">
          <Download aria-hidden="true" /> Descargar <ChevronDown aria-hidden="true" />
        </Button>
      </DropdownMenuTrigger>
      <DropdownMenuContent align="end">
        <DropdownMenuLabel className="text-xs font-normal text-muted-foreground">
          {dirty ? "Guarda para incluir los cambios" : "Diseño guardado"}
        </DropdownMenuLabel>
        <DropdownMenuSeparator />
        {PNG_SIZES.map((s) => item(qrUrl(linkId, "png", { size: s, template }), `PNG ${s} px`))}
        {item(qrUrl(linkId, "svg", { template }), "SVG (vector)")}
        {item(qrUrl(linkId, "pdf", { template }), "PDF")}
      </DropdownMenuContent>
    </DropdownMenu>
  );
}
