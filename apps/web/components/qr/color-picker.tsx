"use client";

import { useId, useState } from "react";

import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";

const HEX = /^#(?:[0-9a-fA-F]{3}|[0-9a-fA-F]{6})$/;

function toSix(v: string) {
  return v.length === 4 ? `#${[...v.slice(1)].map((c) => c + c).join("")}` : v;
}

/** Selector nativo + campo hex; solo emite valores válidos. */
export function ColorPicker({
  label, value, onChange, disabled,
}: { label: string; value: string; onChange: (v: string) => void; disabled?: boolean }) {
  const id = useId();
  const [text, setText] = useState(value);
  const [prev, setPrev] = useState(value);
  if (prev !== value) {
    setPrev(value);
    setText(value);
  }
  const invalid = !HEX.test(text);
  return (
    <div className="grid gap-1.5">
      <Label htmlFor={id}>{label}</Label>
      <div className="flex items-center gap-2">
        <input
          type="color"
          aria-label={`${label} (selector)`}
          value={toSix(value)}
          disabled={disabled}
          onChange={(e) => onChange(e.target.value)}
          className="size-9 shrink-0 cursor-pointer rounded-md border border-input bg-transparent p-1 disabled:cursor-not-allowed disabled:opacity-50"
        />
        <Input
          id={id}
          value={text}
          disabled={disabled}
          maxLength={7}
          spellCheck={false}
          aria-invalid={invalid}
          className="font-mono"
          onChange={(e) => {
            setText(e.target.value);
            if (HEX.test(e.target.value)) onChange(e.target.value);
          }}
        />
      </div>
      {invalid ? <p className="text-xs text-destructive">Usa formato #RRGGBB.</p> : null}
    </div>
  );
}
