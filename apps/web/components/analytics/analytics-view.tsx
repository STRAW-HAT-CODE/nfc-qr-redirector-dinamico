import { ScanLine } from "lucide-react";

import { eachDay } from "@/lib/stats-range";
import type { Stats } from "@/lib/api";

import { EmptyState } from "@/components/empty-state";
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";

import { BreakdownTables } from "./breakdown-tables";
import { KpiCards } from "./kpi-cards";
import { ScansChart } from "./scans-chart";

export interface StatsBundle {
  day: Stats;
  channel: Stats;
  country: Stats;
  device: Stats;
}

/** KPIs + gráfico + desgloses. `emptyHint` explica cómo generar los primeros escaneos. */
export function AnalyticsView({ data, emptyHint }: { data: StatsBundle; emptyHint: string }) {
  const { day, channel, country, device } = data;
  if (day.totals.scans === 0) {
    return (
      <EmptyState
        icon={<ScanLine />}
        title="Sin escaneos en este rango"
        description={`Todavía no hay datos. ${emptyHint} Los escaneos tardan unos segundos en aparecer.`}
      />
    );
  }
  const byDay = new Map(day.series.map((p) => [p.key, p]));
  const points = eachDay(day.from, day.to).map((d) => ({
    day: d,
    scans: byDay.get(d)?.scans ?? 0,
    unique: byDay.get(d)?.unique_visitors ?? 0,
  }));
  return (
    <>
      <KpiCards scans={day.totals.scans} unique={day.totals.unique_visitors} />
      <Card className="mb-6">
        <CardHeader>
          <CardTitle>Escaneos por día</CardTitle>
        </CardHeader>
        <CardContent>
          <ScansChart data={points} />
        </CardContent>
      </Card>
      <BreakdownTables channel={channel.series} country={country.series} device={device.series} />
    </>
  );
}

export function AnalyticsSkeleton() {
  return null;
}
