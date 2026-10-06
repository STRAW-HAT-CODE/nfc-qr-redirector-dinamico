"use client";

import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import type { QrFrame } from "@/lib/api";
import { cn } from "@/lib/utils";

const FRAMES: { value: QrFrame; label: string }[] = [
  { value: "none", label: "Sin marco" },
  { value: "simple", label: "Simple" },
  { value: "rounded", label: "Redondeado" },
  { value: "label", label: "Con texto" },
];

export function FramePicker({
  frame, text, onFrame, onText, disabled,
}: {
  frame: QrFrame; text: string; onFrame: (f: QrFrame) => void; onText: (t: string) => void; disabled?: boolean;
}) {
  return (
    <fieldset className="grid gap-3" disabled={disabled}>
      <legend className="mb-1.5 text-sm font-medium">Marco</legend>
      <div role="radiogroup" aria-label="Marco" className="grid grid-cols-2 gap-2 sm:grid-cols-4 lg:grid-cols-2 xl:grid-cols-4">
        {FRAMES.map((f) => (
          <button
            key={f.value}
            type="button"
            role="radio"
            aria-checked={frame === f.value}
            onClick={() => onFrame(f.value)}
            className={cn(
              "rounded-md border px-2 py-2 text-sm transition-colors outline-none focus-visible:ring-[3px] focus-visible:ring-ring/50 disabled:opacity-50",
              frame === f.value ? "border-primary bg-primary/10 font-medium" : "border-input hover:bg-accent",
            )}
          >
            {f.label}
          </button>
        ))}
      </div>
      {frame === "label" ? (
        <div className="grid gap-1.5">
          <Label htmlFor="frame-text">Texto del marco</Label>
          <Input id="frame-text" value={text} maxLength={30} placeholder="Escanéame" onChange={(e) => onText(e.target.value)} />
        </div>
      ) : null}
    </fieldset>
  );
}
