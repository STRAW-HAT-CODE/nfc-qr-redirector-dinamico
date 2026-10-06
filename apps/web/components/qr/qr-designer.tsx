"use client";

import { Loader2, Save } from "lucide-react";
import { useEffect, useState, useTransition } from "react";
import { toast } from "sonner";

import { saveDesignAction } from "@/app/(app)/links/[id]/design/actions";
import { Button } from "@/components/ui/button";
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";
import { Label } from "@/components/ui/label";
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from "@/components/ui/select";
import type { EccLevel, ModuleStyle, QrDesign, QrFrame } from "@/lib/api";

import { CanvaButton } from "./canva-button";
import { ColorPicker } from "./color-picker";
import { ContrastWarning } from "./contrast-warning";
import { DownloadMenu } from "./download-menu";
import { FramePicker } from "./frame-picker";
import { LogoUpload } from "./logo-upload";
import { QrPreview } from "./qr-preview";
import { QuickDesigns } from "./quick-designs";
import { TemplatesGallery } from "./templates-gallery";

interface Draft {
  fg: string;
  bg: string;
  ecc_level: EccLevel;
  frame: QrFrame;
  frame_text: string;
  module_style: ModuleStyle;
  margin: number;
}

const toDraft = (d: QrDesign): Draft => ({
  fg: d.fg, bg: d.bg, ecc_level: d.has_logo || d.style?.logo_preset ? "H" : d.ecc_level, frame: d.frame,
  frame_text: d.frame_text ?? "", module_style: d.module_style, margin: d.margin,
});

const PRESET_GOOGLE = { fg: "#000000", bg: "#FFFFFF", frame: "none", module_style: "square" } as const;
const GOOGLE_G = "/presets/google-g.svg";

const ECC: Record<EccLevel, string> = { L: "L · 7 %", M: "M · 15 %", Q: "Q · 25 %", H: "H · 30 %" };
const STYLES: Record<ModuleStyle, string> = { square: "Cuadrados", rounded: "Redondeados", dots: "Puntos" };

export function QrDesigner({
  linkId, shortUrl, initial, canEdit,
}: { linkId: string; shortUrl: string; initial: QrDesign; canEdit: boolean }) {
  const [saved, setSaved] = useState(initial);
  const [draft, setDraft] = useState<Draft>(() => toDraft(initial));
  const [logoUrl, setLogoUrl] = useState<string | null>(null);
  const [error, setError] = useState<string>();
  const [pending, start] = useTransition();

  useEffect(() => () => { if (logoUrl) URL.revokeObjectURL(logoUrl); }, [logoUrl]);

  const set = <K extends keyof Draft>(k: K, v: Draft[K]) => setDraft((d) => ({ ...d, [k]: v }));
  const base = toDraft(saved);
  const dirty = (Object.keys(draft) as (keyof Draft)[]).some((k) => draft[k] !== base[k]);
  const locked = !canEdit || pending;
  const preset = saved.style?.logo_preset ?? null;
  const [presetBusy, startPreset] = useTransition();

  function applyPreset(on: boolean) {
    setError(undefined);
    startPreset(async () => {
      const input = on
        ? { ...PRESET_GOOGLE, ecc_level: "H" as const, margin: saved.margin, frame_text: null, style: { logo_preset: "google" as const } }
        : { ...toDraft(saved), frame_text: saved.frame === "label" ? saved.frame_text : null, style: { logo_preset: null } };
      const res = await saveDesignAction(linkId, input);
      if (res.ok) {
        setSaved(res.design);
        setDraft(toDraft(res.design));
        toast.success(on ? "Diseño «Reseñas de Google» aplicado" : "Diseño rápido quitado");
      } else setError(res.message);
    });
  }

  function save() {
    setError(undefined);
    start(async () => {
      const res = await saveDesignAction(linkId, {
        ...draft, frame_text: draft.frame === "label" ? draft.frame_text : null,
        ...(preset ? { style: { logo_preset: preset } } : {}),
      });
      if (res.ok) {
        setSaved(res.design);
        setDraft(toDraft(res.design));
        toast.success("Diseño guardado");
      } else setError(res.message);
    });
  }

  function onLogo(design: QrDesign, url: string | null) {
    setLogoUrl(url);
    setSaved((s) => ({ ...s, has_logo: design.has_logo, warnings: design.warnings }));
    // Con logo el ECC pasa a H (el servidor lo exige); lo reflejamos como cambio sin guardar.
    if (design.has_logo) set("ecc_level", "H");
  }

  return (
    <div className="grid gap-6 lg:grid-cols-[minmax(0,1fr)_380px]">
      <div className="grid content-start gap-6">
        <Card>
          <CardHeader className="flex-row items-center justify-between gap-2">
            <CardTitle>Vista previa</CardTitle>
            <span className="text-xs text-muted-foreground" aria-live="polite">
              {dirty ? "Cambios sin guardar" : saved.is_default ? "Diseño por defecto" : "Guardado"}
            </span>
          </CardHeader>
          <CardContent className="grid justify-items-center gap-4">
            <QrPreview
              data={`${shortUrl}?c=q`} fg={draft.fg} bg={draft.bg} ecc={saved.has_logo || preset ? "H" : draft.ecc_level}
              frame={draft.frame} frameText={draft.frame_text} moduleStyle={draft.module_style}
              margin={draft.margin} hasLogo={saved.has_logo || !!preset} logoUrl={preset ? GOOGLE_G : logoUrl}
            />
            <p className="max-w-sm text-center text-xs text-muted-foreground">
              Aproximación en vivo. Las descargas usan el diseño guardado.
            </p>
            <div className="flex flex-wrap items-center justify-center gap-3">
              <DownloadMenu linkId={linkId} dirty={dirty} />
              <CanvaButton linkId={linkId} />
            </div>
          </CardContent>
        </Card>
        <TemplatesGallery />
      </div>

      <Card className="content-start">
        <CardHeader>
          <CardTitle>Diseño</CardTitle>
        </CardHeader>
        <CardContent className="grid gap-5">
          {!canEdit ? (
            <p className="rounded-md bg-muted px-3 py-2 text-sm text-muted-foreground">
              Tu rol es de lectura: puedes ver y descargar, pero no editar.
            </p>
          ) : null}
          <div className="grid grid-cols-2 gap-3">
            <ColorPicker label="Color del QR" value={draft.fg} onChange={(v) => set("fg", v)} disabled={locked} />
            <ColorPicker label="Fondo" value={draft.bg} onChange={(v) => set("bg", v)} disabled={locked} />
          </div>
          {canEdit ? (
            <QuickDesigns active={!!preset} onApply={() => applyPreset(true)} onRemove={() => applyPreset(false)} disabled={pending} busy={presetBusy} />
          ) : null}
          <ContrastWarning fg={draft.fg} bg={draft.bg} serverWarnings={saved.warnings} />

          <div className="grid gap-1.5">
            <Label htmlFor="module-style">Estilo de módulos</Label>
            <Select value={draft.module_style} onValueChange={(v) => set("module_style", v as ModuleStyle)} disabled={locked}>
              <SelectTrigger id="module-style" className="w-full"><SelectValue /></SelectTrigger>
              <SelectContent>
                {Object.entries(STYLES).map(([v, l]) => <SelectItem key={v} value={v}>{l}</SelectItem>)}
              </SelectContent>
            </Select>
          </div>

          <div className="grid gap-1.5">
            <Label htmlFor="ecc">Corrección de errores</Label>
            <Select value={draft.ecc_level} onValueChange={(v) => set("ecc_level", v as EccLevel)} disabled={locked || saved.has_logo || !!preset}>
              <SelectTrigger id="ecc" className="w-full" aria-describedby="ecc-help"><SelectValue /></SelectTrigger>
              <SelectContent>
                {Object.entries(ECC).map(([v, l]) => <SelectItem key={v} value={v}>{l}</SelectItem>)}
              </SelectContent>
            </Select>
            <p id="ecc-help" className="text-xs text-muted-foreground">
              {saved.has_logo || preset
                ? "Bloqueado en H: el logo tapa parte del código y necesita la máxima corrección."
                : "Más corrección tolera más daño, pero el QR es más denso."}
            </p>
          </div>

          <div className="grid gap-1.5">
            <Label htmlFor="margin">Margen: {draft.margin} módulos</Label>
            <input id="margin" type="range" min={0} max={16} value={draft.margin} disabled={locked}
              onChange={(e) => set("margin", Number(e.target.value))} className="accent-primary" />
          </div>

          <FramePicker frame={draft.frame} text={draft.frame_text} onFrame={(f) => set("frame", f)} onText={(t) => set("frame_text", t)} disabled={locked} />

          <LogoUpload linkId={linkId} hasLogo={saved.has_logo} localUrl={logoUrl} onChange={onLogo} disabled={locked} />

          {error ? <p role="alert" className="text-sm text-destructive">{error}</p> : null}
          {canEdit ? (
            <div className="flex gap-2">
              <Button onClick={save} disabled={!dirty || pending}>
                {pending ? <Loader2 className="animate-spin" /> : <Save />} Guardar
              </Button>
              <Button variant="ghost" onClick={() => setDraft(toDraft(saved))} disabled={!dirty || pending}>
                Descartar
              </Button>
            </div>
          ) : null}
        </CardContent>
      </Card>
    </div>
  );
}
