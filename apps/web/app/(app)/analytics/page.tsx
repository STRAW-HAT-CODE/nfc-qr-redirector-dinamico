import { AnalyticsView } from "@/components/analytics/analytics-view";
import { DateRange } from "@/components/analytics/date-range";
import { ErrorState } from "@/components/error-state";
import { PageHeader } from "@/components/page-header";
import { ApiError, getStatsBundle, requireActiveOrg } from "@/lib/api";
import { resolveRange } from "@/lib/stats-range";

export const metadata = { title: "Analytics · Dynamic QR" };

type SP = Promise<{ range?: string; from?: string; to?: string }>;

export default async function Page({ searchParams }: { searchParams: SP }) {
  const range = resolveRange(await searchParams);
  const { active } = await requireActiveOrg();

  let data;
  try {
    data = await getStatsBundle(active.id, range);
  } catch (e) {
    return (
      <>
        <PageHeader title="Analytics" description={active.name} />
        <DateRange basePath="/analytics" value={range} />
        <ErrorState message={e instanceof ApiError ? e.message : "No se pudieron cargar las métricas."} />
      </>
    );
  }

  return (
    <>
      <PageHeader title="Analytics" description={active.name} />
      <DateRange basePath="/analytics" value={range} />
      <AnalyticsView
        data={data}
        emptyHint="Crea un enlace, escanea su QR con tu móvil (o ábrelo en el navegador) y vuelve aquí."
      />
    </>
  );
}
