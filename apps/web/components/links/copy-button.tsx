"use client";

import { Check, Copy } from "lucide-react";
import { useState } from "react";
import { toast } from "sonner";

import { Button } from "@/components/ui/button";

export function CopyButton({ value, label = "Copiar enlace corto" }: { value: string; label?: string }) {
  const [copied, setCopied] = useState(false);
  async function copy() {
    try {
      await navigator.clipboard.writeText(value);
      setCopied(true);
      toast.success("Copiado al portapapeles");
      setTimeout(() => setCopied(false), 1500);
    } catch {
      toast.error("No se pudo copiar. Cópialo manualmente.");
    }
  }
  return (
    <Button type="button" variant="ghost" size="icon" onClick={copy} aria-label={label} title={label}>
      {copied ? <Check /> : <Copy />}
    </Button>
  );
}
