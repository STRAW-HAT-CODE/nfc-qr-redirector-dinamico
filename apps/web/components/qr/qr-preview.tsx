"use client";

import qrcode from "qrcode-generator";
import { useEffect, useMemo, useState } from "react";

import type { EccLevel, ModuleStyle, QrFrame } from "@/lib/api";

export interface PreviewParams {
  data: string;
  fg: string;
  bg: string;
  ecc: EccLevel;
  frame: QrFrame;
  frameText: string;
  moduleStyle: ModuleStyle;
  margin: number;
  hasLogo: boolean;
  logoUrl?: string | null;
}

function useDebounced<T>(value: T, ms: number): T {
  const [v, setV] = useState(value);
  useEffect(() => {
    const t = setTimeout(() => setV(value), ms);
    return () => clearTimeout(t);
  }, [value, ms]);
  return v;
}

/**
 * Vista previa en vivo, sin guardar. La API solo renderiza el diseño ya guardado,
 * así que aquí se dibuja una aproximación local (mismos colores, ECC, marco y logo).
 */
export function QrPreview(props: PreviewParams) {
  const p = useDebounced(props, 150);
  const { cells, n } = useMemo(() => {
    try {
      const qr = qrcode(0, p.ecc);
      qr.addData(p.data);
      qr.make();
      const n = qr.getModuleCount();
      const cells: [number, number][] = [];
      for (let r = 0; r < n; r++) for (let c = 0; c < n; c++) if (qr.isDark(r, c)) cells.push([c, r]);
      return { cells, n };
    } catch {
      return { cells: [], n: 0 };
    }
  }, [p.data, p.ecc]);

  if (!n) {
    return <p role="alert" className="text-sm text-destructive">No se pudo generar la vista previa (contenido demasiado largo).</p>;
  }

  const m = p.margin;
  const side = n + m * 2;
  const pad = p.frame === "none" ? 0 : 1.5;
  const labelH = p.frame === "label" ? 4 : 0;
  const W = side + pad * 2;
  const H = W + labelH;
  const rx = p.moduleStyle === "dots" ? 0.5 : p.moduleStyle === "rounded" ? 0.3 : 0;
  const logo = side * 0.2;
  const text = p.frameText.trim() || "Escanéame";

  return (
    <svg
      viewBox={`0 0 ${W} ${H}`}
      role="img"
      aria-label={`Vista previa del QR${p.frame === "label" ? ` con marco «${text}»` : ""}`}
      className="h-auto w-full max-w-sm rounded-lg shadow-sm ring-1 ring-border"
    >
      <rect width={W} height={H} fill={p.bg} rx={p.frame === "rounded" ? 2 : 0} />
      {p.frame !== "none" && (
        <rect
          x={0.4} y={0.4} width={W - 0.8} height={H - 0.8}
          rx={p.frame === "rounded" ? 2 : 0}
          fill="none" stroke={p.fg} strokeWidth={0.6}
        />
      )}
      <g transform={`translate(${pad + m} ${pad + m})`} fill={p.fg}>
        {cells.map(([x, y]) => (
          <rect key={`${x}-${y}`} x={x} y={y} width={1.02} height={1.02} rx={rx} />
        ))}
      </g>
      {p.hasLogo && (
        <g transform={`translate(${pad + side / 2 - logo / 2} ${pad + side / 2 - logo / 2})`}>
          <rect width={logo} height={logo} fill={p.bg} rx={logo * 0.12} />
          {p.logoUrl ? (
            <image href={p.logoUrl} x={logo * 0.08} y={logo * 0.08} width={logo * 0.84} height={logo * 0.84} preserveAspectRatio="xMidYMid meet" />
          ) : (
            <rect x={logo * 0.15} y={logo * 0.15} width={logo * 0.7} height={logo * 0.7} rx={logo * 0.1} fill={p.fg} opacity={0.15} />
          )}
        </g>
      )}
      {p.frame === "label" && (
        <text x={W / 2} y={W + labelH / 2 + 0.3} textAnchor="middle" dominantBaseline="middle" fontSize={1.9} fontWeight={700} fill={p.fg} fontFamily="system-ui, sans-serif">
          {text}
        </text>
      )}
    </svg>
  );
}
