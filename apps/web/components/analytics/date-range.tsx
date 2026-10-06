import Link from "next/link";

import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { MAX_DAYS, PRESETS, type DateRangeValue } from "@/lib/stats-range";

/** Selector de rango en la URL (searchParams): presets como enlaces y personalizado como form GET. */
export function DateRange({ basePath, value }: { basePath: string; value: DateRangeValue }) {
  const today = new Date().toISOString().slice(0, 10);
  return (
    <div className="mb-6 flex flex-wrap items-end gap-x-6 gap-y-3">
      <nav aria-label="Rango de fechas" className="flex gap-1">
        {PRESETS.map((d) => (
          <Button
            key={d}
            asChild
            size="sm"
            variant={value.preset === d ? "default" : "outline"}
          >
            <Link href={`${basePath}?range=${d}`} aria-current={value.preset === d ? "true" : undefined}>
              {d} días
            </Link>
          </Button>
        ))}
      </nav>
      <form method="get" action={basePath} className="flex flex-wrap items-end gap-2">
        <div className="grid gap-1">
          <Label htmlFor="range-from" className="text-xs">
            Desde
          </Label>
          <Input id="range-from" name="from" type="date" required defaultValue={value.from} max={today} className="h-8 w-auto" />
        </div>
        <div className="grid gap-1">
          <Label htmlFor="range-to" className="text-xs">
            Hasta
          </Label>
          <Input id="range-to" name="to" type="date" required defaultValue={value.to} max={today} className="h-8 w-auto" />
        </div>
        <Button type="submit" size="sm" variant={value.preset === null ? "default" : "outline"}>
          Aplicar
        </Button>
      </form>
      <p className="text-xs text-muted-foreground">Máximo {MAX_DAYS} días · fechas en UTC</p>
      {value.notice ? (
        <p role="alert" className="basis-full text-sm text-destructive">
          {value.notice}
        </p>
      ) : null}
    </div>
  );
}
