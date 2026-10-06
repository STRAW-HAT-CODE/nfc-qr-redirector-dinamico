/** Rango de fechas de analytics (UTC, como la API). Puro: sin dependencias de servidor. */

export const PRESETS = [7, 30, 90] as const;
export const DEFAULT_DAYS = 30;
export const MAX_DAYS = 366;

export interface DateRangeValue {
  from: string;
  to: string;
  /** 7 | 30 | 90 si es un preset; null si es personalizado. */
  preset: number | null;
  /** Mensaje si hubo que corregir parámetros inválidos. */
  notice?: string;
}

const ISO = /^\d{4}-\d{2}-\d{2}$/;
const DAY_MS = 86_400_000;

const toIso = (d: Date) => d.toISOString().slice(0, 10);
const parse = (s: string | undefined) => {
  if (!s || !ISO.test(s)) return null;
  const d = new Date(`${s}T00:00:00Z`);
  return Number.isNaN(d.getTime()) || toIso(d) !== s ? null : d;
};
const addDays = (d: Date, n: number) => new Date(d.getTime() + n * DAY_MS);

export function resolveRange(sp: { range?: string; from?: string; to?: string }, now = new Date()): DateRangeValue {
  const today = parse(toIso(now))!;
  const presetRange = (days: number): DateRangeValue => ({
    from: toIso(addDays(today, -(days - 1))),
    to: toIso(today),
    preset: days,
  });

  const from = parse(sp.from);
  const to = parse(sp.to);
  if (sp.from || sp.to) {
    if (from && to) {
      const span = Math.round((to.getTime() - from.getTime()) / DAY_MS) + 1;
      if (span < 1) return { ...presetRange(DEFAULT_DAYS), notice: "«Desde» debe ser anterior o igual a «hasta»." };
      if (span > MAX_DAYS)
        return { ...presetRange(DEFAULT_DAYS), notice: `El rango máximo es de ${MAX_DAYS} días.` };
      if (to > today) return { ...presetRange(DEFAULT_DAYS), notice: "La fecha final no puede ser futura." };
      return { from: sp.from!, to: sp.to!, preset: null };
    }
    return { ...presetRange(DEFAULT_DAYS), notice: "Rango personalizado inválido; se muestran los últimos 30 días." };
  }
  const days = Number(sp.range);
  return presetRange((PRESETS as readonly number[]).includes(days) ? days : DEFAULT_DAYS);
}

/** Todas las fechas del rango (inclusive), para rellenar días sin escaneos. */
export function eachDay(from: string, to: string): string[] {
  const out: string[] = [];
  const end = parse(to);
  for (let d = parse(from); d && end && d <= end && out.length <= MAX_DAYS; d = addDays(d, 1)) out.push(toIso(d));
  return out;
}

export interface Row {
  key: string;
  scans: number;
}

/** Top N ordenado + «otros» (suma del resto y de cualquier clave "other" de la API). */
export function topWithOthers(series: Row[], n = 5): Row[] {
  const known = series.filter((r) => r.key !== "other").sort((a, b) => b.scans - a.scans);
  const rest = known.slice(n).reduce((s, r) => s + r.scans, 0) + series.filter((r) => r.key === "other").reduce((s, r) => s + r.scans, 0);
  const top = known.slice(0, n);
  return rest > 0 ? [...top, { key: "other", scans: rest }] : top;
}
