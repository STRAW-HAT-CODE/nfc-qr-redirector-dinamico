"use client";

import { Loader2, Save } from "lucide-react";
import { useEffect, useState, useTransition } from "react";
import { toast } from "sonner";

import { saveDesignAction } from "@/app/(app)/links/[id]/design/actions";
import { Button } from "@/components/ui/button";
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";
import { Label } from "@/components/ui/label";
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from "@/components/ui/select";
import type { EccLevel, ImageMode, ModuleStyle, QrDesign, QrFrame } from "@/lib/api";

import { CanvaButton } from "./canva-button";
import { ColorPicker } from "./color-picker";
import { ContrastWarning } from "./contrast-warning";
import { DownloadMenu } from "./download-menu";
import { FramePicker } from "./frame-picker";
import { LogoUpload } from "./logo-upload";
import { QrPreview } from "./qr-preview";
import { QuickDesigns } from "./quick-designs";

interface Draft {
  fg: string;
  bg: string;
  ecc_level: EccLevel;
  frame: QrFrame;
  frame_text: string;
  module_style: ModuleStyle;
  margin: number;
  bg_transparent: boolean;
  image_mode: ImageMode;
  image_intensity: number;
  image_contrast: number;
}

const toDraft = (d: QrDesign): Draft => {
  const imageMode = d.image_mode ?? d.style?.image_mode ?? "none";
  return {
    fg: d.fg, bg: d.bg,
    ecc_level: d.has_logo || d.style?.logo_preset || imageMode !== "none" ? "H" : d.ecc_level,
    frame: d.frame, frame_text: d.frame_text ?? "", module_style: d.module_style, margin: d.margin,
    bg_transparent: !!d.style?.bg_transparent,
    image_mode: imageMode,
    image_intensity: d.style?.image_intensity ?? 0.8,
    image_contrast: d.style?.image_contrast ?? 1,
  };
};

const PRESET_GOOGLE = { fg: "#000000", bg: "#FFFFFF", frame: "none", module_style: "square" } as const;
const GOOGLE_G = "/presets/google-g.svg";

/** Campos que van en el cuerpo del PUT; `style` se envía aparte (evita 422 por extras). */
const toDesignBody = (d: Draft) => {
  const { bg_transparent, image_mode, image_intensity, image_contrast, ...rest } = d;
  void bg_transparent;
  void image_mode;
  void image_intensity;
  void image_contrast;
  return rest;
};

const ECC: Record<EccLevel, string> = { L: "L · 7 %", M: "M · 15 %", Q: "Q · 25 %", H: "H · 30 %" };
const STYLES: Record<ModuleStyle, string> = { square: "Cuadrados", rounded: "Redondeados", dots: "Puntos" };
const IMAGE_MODES: Record<ImageMode, string> = {
  none: "Solo logo (centro)",
  tint: "Tinte por módulo",
  silhouette: "Silueta",
  halftone: "Halftone (puntos)",
  photo: "Foto",
};

export function QrDesigner({
  linkId, shortUrl, initial, canEdit,
}: { linkId: string; shortUrl: string; initial: QrDesign; canEdit: boolean }) {
  const [saved, setSaved] = useState(initial);
  const [draft, setDraft] = useState<Draft>(() => toDraft(initial));
  const [logoUrl, setLogoUrl] = useState<string | null>(null);
  const [error, setError] = useState<string>();
  const [pending, start] = useTransition();

  useEffect(() => () => { if (logoUrl?.startsWith("blob:")) URL.revokeObjectURL(logoUrl); }, [logoUrl]);
  const effectiveLogoUrl = logoUrl ?? (saved.has_logo ? `/api/qr/${linkId}/logo?t=${encodeURIComponent(saved.updated_at ?? "1")}` : null);

  const set = <K extends keyof Draft>(k: K, v: Draft[K]) => setDraft((d) => ({ ...d, [k]: v }));
  const base = toDraft(saved);
  const dirty = (Object.keys(draft) as (keyof Draft)[]).some((k) => draft[k] !== base[k]);
  const locked = !canEdit || pending;
  const preset = saved.style?.logo_preset ?? null;
  const [presetBusy, startPreset] = useTransition();
  const imageOn = draft.image_mode !== "none";
  const eccLocked = saved.has_logo || !!preset || imageOn;

  function applyPreset(on: boolean) {
    setError(undefined);
    startPreset(async () => {
      const input = on
        ? {
            ...PRESET_GOOGLE,
            ecc_level: "H" as const,
            margin: saved.margin,
            frame_text: null,
            style: {
              logo_preset: "google" as const,
              bg_transparent: draft.bg_transparent,
              image_mode: "none" as const,
              image_intensity: 0.8,
              image_contrast: 1,
            },
          }
        : {
            ...toDesignBody(toDraft(saved)),
            frame_text: saved.frame === "label" ? saved.frame_text : null,
            style: {
              logo_preset: null,
              bg_transparent: !!saved.style?.bg_transparent,
              image_mode: draft.image_mode,
              image_intensity: draft.image_intensity,
              image_contrast: draft.image_contrast,
            },
          };
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
        ...toDesignBody(draft), frame_text: draft.frame === "label" ? draft.frame_text : null,
        style: {
          logo_preset: draft.image_mode === "none" ? preset : null,
          bg_transparent: draft.bg_transparent,
          image_mode: draft.image_mode,
          image_intensity: draft.image_intensity,
          image_contrast: draft.image_contrast,
        },
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
    // Subir una imagen sustituye el logo de Google; el estilo se persiste al guardar.
    const imageMode = design.image_mode ?? "none";
    setSaved((s) => ({
      ...s,
      has_logo: design.has_logo,
      logo_preset: null,
      image_mode: imageMode,
      style: { ...s.style, logo_preset: null, image_mode: imageMode },
      warnings: design.warnings,
    }));
    // Con logo el ECC pasa a H (el servidor lo exige); lo reflejamos como cambio sin guardar.
    if (design.has_logo) set("ecc_level", "H");
    else set("image_mode", "none"); // sin imagen no hay modo imagen
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
              data={`${shortUrl}?c=q`} fg={draft.fg} bg={draft.bg} transparent={draft.bg_transparent && !imageOn} ecc={eccLocked ? "H" : draft.ecc_level}
              frame={draft.frame} frameText={draft.frame_text} moduleStyle={draft.module_style}
              margin={draft.margin} hasLogo={saved.has_logo || !!preset} logoUrl={preset ? GOOGLE_G : effectiveLogoUrl}
              imageMode={draft.image_mode} imageUrl={effectiveLogoUrl}
            />
            <p className="max-w-sm text-center text-xs text-muted-foreground">
              Aproximación en vivo. Las descargas usan el diseño guardado.{" "}
              <a className="underline underline-offset-2" href={`/api/qr/${linkId}/png?size=1024`} target="_blank" rel="noreferrer">
                Ver render real
              </a>
            </p>
            <div className="flex flex-wrap items-center justify-center gap-3">
              <DownloadMenu linkId={linkId} dirty={dirty} />
              <CanvaButton linkId={linkId} />
            </div>
          </CardContent>
        </Card>
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
            <ColorPicker label="Fondo" value={draft.bg} onChange={(v) => set("bg", v)} disabled={locked || draft.bg_transparent} />
          </div>
          <label className="flex cursor-pointer items-start gap-3 text-sm">
            <input
              type="checkbox" role="switch" checked={draft.bg_transparent} disabled={locked || imageOn}
              onChange={(e) => set("bg_transparent", e.target.checked)}
              aria-describedby="bg-transparent-help" className="peer sr-only"
            />
            <span
              aria-hidden="true"
              className="relative mt-0.5 h-5 w-9 shrink-0 rounded-full bg-input transition-colors after:absolute after:left-0.5 after:top-0.5 after:size-4 after:rounded-full after:bg-background after:shadow after:transition-transform peer-checked:bg-primary peer-checked:after:translate-x-4 peer-focus-visible:ring-2 peer-focus-visible:ring-ring peer-disabled:opacity-50"
            />
            <span className="grid gap-0.5">
              <span className="font-medium">Fondo transparente</span>
              <span id="bg-transparent-help" className="text-xs text-muted-foreground">
                {imageOn
                  ? "En modo imagen el fondo se fuerza opaco para conservar el contraste."
                  : "PNG y SVG sin fondo, para colocar sobre tus diseños (p. ej. Canva). El PDF mantiene fondo blanco."}
              </span>
            </span>
          </label>
          {canEdit ? (
            <QuickDesigns active={!!preset} onApply={() => applyPreset(true)} onRemove={() => applyPreset(false)} disabled={pending} busy={presetBusy} />
          ) : null}
          <ContrastWarning fg={draft.fg} bg={draft.bg} transparent={draft.bg_transparent} serverWarnings={saved.warnings} />

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
            <Select value={draft.ecc_level} onValueChange={(v) => set("ecc_level", v as EccLevel)} disabled={locked || eccLocked}>
              <SelectTrigger id="ecc" className="w-full" aria-describedby="ecc-help"><SelectValue /></SelectTrigger>
              <SelectContent>
                {Object.entries(ECC).map(([v, l]) => <SelectItem key={v} value={v}>{l}</SelectItem>)}
              </SelectContent>
            </Select>
            <p id="ecc-help" className="text-xs text-muted-foreground">
              {eccLocked
                ? "Bloqueado en H: el logo o la imagen tapa parte del código y necesita la máxima corrección."
                : "Más corrección tolera más daño, pero el QR es más denso."}
            </p>
          </div>

          <div className="grid gap-1.5">
            <Label htmlFor="margin">Margen: {draft.margin} módulos</Label>
            <input id="margin" type="range" min={0} max={16} value={draft.margin} disabled={locked}
              onChange={(e) => set("margin", Number(e.target.value))} className="accent-primary" />
          </div>

          <FramePicker frame={draft.frame} text={draft.frame_text} onFrame={(f) => set("frame", f)} onText={(t) => set("frame_text", t)} disabled={locked} />

          <LogoUpload linkId={linkId} hasLogo={saved.has_logo} localUrl={effectiveLogoUrl} onChange={onLogo} disabled={locked} />

          <div className="grid gap-1.5">
            <Label htmlFor="image-mode">Imagen en el QR</Label>
            <Select
              value={draft.image_mode}
              onValueChange={(v) => {
                const mode = v as ImageMode;
                set("image_mode", mode);
                if (mode !== "none") set("bg_transparent", false);
              }}
              disabled={locked || !saved.has_logo}
            >
              <SelectTrigger id="image-mode" className="w-full"><SelectValue /></SelectTrigger>
              <SelectContent>
                {Object.entries(IMAGE_MODES).map(([v, l]) => <SelectItem key={v} value={v}>{l}</SelectItem>)}
              </SelectContent>
            </Select>
            <p className="text-xs text-muted-foreground">
              {saved.has_logo
                ? "La imagen subida se usa como relleno del QR. La vista previa es aproximada; descarga el PNG o SVG para comprobarla."
                : "Sube primero un logo o imagen para activar los modos de imagen."}
            </p>
          </div>

          {imageOn ? (
            <div className="grid gap-3">
              <div className="grid gap-1.5">
                <Label htmlFor="image-intensity">Intensidad de imagen: {draft.image_intensity.toFixed(2)}</Label>
                <input
                  id="image-intensity" type="range" min={0} max={1} step={0.05}
                  value={draft.image_intensity} disabled={locked}
                  onChange={(e) => set("image_intensity", Number(e.target.value))}
                  className="accent-primary"
                />
              </div>
              <div className="grid gap-1.5">
                <Label htmlFor="image-contrast">Contraste de imagen: {draft.image_contrast.toFixed(2)}</Label>
                <input
                  id="image-contrast" type="range" min={0.5} max={2} step={0.05}
                  value={draft.image_contrast} disabled={locked}
                  onChange={(e) => set("image_contrast", Number(e.target.value))}
                  className="accent-primary"
                />
              </div>
            </div>
          ) : null}

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
