/** Contraste WCAG entre dos colores hex (#rgb o #rrggbb) para avisar de QR poco escaneables. */

export function parseHex(hex: string): [number, number, number] | null {
  const m = /^#([0-9a-f]{3}|[0-9a-f]{6})$/i.exec(hex.trim());
  if (!m) return null;
  let h = m[1];
  if (h.length === 3) h = [...h].map((c) => c + c).join("");
  const n = parseInt(h, 16);
  return [(n >> 16) & 255, (n >> 8) & 255, n & 255];
}

export function luminance([r, g, b]: [number, number, number]): number {
  const f = (v: number) => {
    const c = v / 255;
    return c <= 0.03928 ? c / 12.92 : ((c + 0.055) / 1.055) ** 2.4;
  };
  return 0.2126 * f(r) + 0.7152 * f(g) + 0.0722 * f(b);
}

export function contrastRatio(a: string, b: string): number | null {
  const ca = parseHex(a);
  const cb = parseHex(b);
  if (!ca || !cb) return null;
  const [l1, l2] = [luminance(ca), luminance(cb)].sort((x, y) => y - x);
  return (l1 + 0.05) / (l2 + 0.05);
}

/** Avisos locales: contraste bajo (<3:1) y QR invertido (frente más claro que el fondo). */
export function contrastWarnings(fg: string, bg: string): string[] {
  const ratio = contrastRatio(fg, bg);
  if (ratio === null) return [];
  const out: string[] = [];
  if (ratio < 3) out.push(`Contraste bajo (${ratio.toFixed(1)}:1). Usa al menos 3:1 para que escanee bien.`);
  const f = parseHex(fg)!;
  const b = parseHex(bg)!;
  if (luminance(f) > luminance(b)) out.push("El color del QR es más claro que el fondo: algunos lectores no lo leen.");
  return out;
}
