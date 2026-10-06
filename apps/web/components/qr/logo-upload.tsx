"use client";

import { ImagePlus, Loader2, Trash2 } from "lucide-react";
import { useRef, useState } from "react";

import { Button } from "@/components/ui/button";
import type { QrDesign } from "@/lib/api";

const TYPES = ["image/png", "image/jpeg", "image/webp"];
const MAX = 1_000_000;

async function parse(res: Response): Promise<{ design?: QrDesign; error?: string }> {
  const data = (await res.json().catch(() => null)) as (QrDesign & { error?: { message?: string } }) | null;
  if (!res.ok) return { error: data?.error?.message ?? `Error ${res.status}` };
  return { design: data as QrDesign };
}

/** Sube/quita el logo al instante (el logo se guarda aparte del resto del diseño). */
export function LogoUpload({
  linkId, hasLogo, localUrl, onChange, disabled,
}: {
  linkId: string; hasLogo: boolean; localUrl: string | null; disabled?: boolean;
  onChange: (design: QrDesign, localUrl: string | null) => void;
}) {
  const input = useRef<HTMLInputElement>(null);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string>();

  async function upload(file: File) {
    setError(undefined);
    if (!TYPES.includes(file.type)) return setError("Formato no admitido. Usa PNG, JPG o WebP.");
    if (file.size > MAX) return setError("El logo supera 1 MB.");
    setBusy(true);
    try {
      const fd = new FormData();
      fd.append("file", file);
      const { design, error } = await parse(await fetch(`/api/qr/${linkId}/logo`, { method: "POST", body: fd }));
      if (design) onChange(design, URL.createObjectURL(file));
      else setError(error);
    } catch {
      setError("No se pudo subir el logo.");
    } finally {
      setBusy(false);
      if (input.current) input.current.value = "";
    }
  }

  async function remove() {
    setError(undefined);
    setBusy(true);
    try {
      const { design, error } = await parse(await fetch(`/api/qr/${linkId}/logo`, { method: "DELETE" }));
      if (design) onChange(design, null);
      else setError(error);
    } catch {
      setError("No se pudo quitar el logo.");
    } finally {
      setBusy(false);
    }
  }

  return (
    <div className="grid gap-2">
      <span className="text-sm font-medium">Logo</span>
      <div className="flex items-center gap-3">
        <div className="flex size-14 shrink-0 items-center justify-center overflow-hidden rounded-md border bg-muted text-muted-foreground">
          {/* eslint-disable-next-line @next/next/no-img-element */}
          {localUrl ? <img src={localUrl} alt="Logo cargado" className="size-full object-contain" /> : <ImagePlus className="size-5" aria-hidden="true" />}
        </div>
        <div className="flex flex-wrap gap-2">
          <input ref={input} type="file" accept={TYPES.join(",")} className="sr-only" aria-label="Archivo de logo" tabIndex={-1}
            onChange={(e) => e.target.files?.[0] && upload(e.target.files[0])} />
          <Button type="button" variant="outline" size="sm" disabled={disabled || busy} onClick={() => input.current?.click()}>
            {busy ? <Loader2 className="animate-spin" /> : <ImagePlus />} {hasLogo ? "Reemplazar" : "Subir logo"}
          </Button>
          {hasLogo ? (
            <Button type="button" variant="ghost" size="sm" disabled={disabled || busy} onClick={remove}>
              <Trash2 /> Quitar
            </Button>
          ) : null}
        </div>
      </div>
      <p className="text-xs text-muted-foreground">PNG, JPG o WebP, hasta 1 MB. Con logo se usa corrección H.</p>
      {error ? <p role="alert" className="text-xs text-destructive">{error}</p> : null}
    </div>
  );
}
