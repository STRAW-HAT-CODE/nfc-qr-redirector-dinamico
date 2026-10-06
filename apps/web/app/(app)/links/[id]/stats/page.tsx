import { ArrowLeft } from "lucide-react";
import Link from "next/link";
import { notFound } from "next/navigation";

import { AnalyticsView } from "@/components/analytics/analytics-view";
import { DateRange } from "@/components/analytics/date-range";
import { ErrorState } from "@/components/error-state";
import { PageHeader } from "@/components/page-header";
import { Button } from "@/components/ui/button";
import { ApiError, getStatsBundle, requireActiveOrg } from "@/lib/api";
import { resolveRange } from "@/lib/stats-range";

import { getLink } from "../../data";

export const metadata = { title: "Métricas del enlace · Dynamic QR" };

type SP = Promise<{ range?: string; from?: string; to?: string }>;

export default async function Page({ params, searchParams }: { params: Promise<{ id: string }>; searchParams: SP }) {
  const { id } = await params;
  const range = resolveRange(await searchParams);
  const { active } = await requireActiveOrg();

  let link;
  try {
    link = await getLink(id);
  } catch (e) {
    if (e instanceof ApiError && (e.status === 404 || e.status === 422)) notFound();
    return <ErrorState message={e instanceof ApiError ? e.message : "No se pudo cargar el enlace."} />;
  }

  let data;
  try {
    data = await getStatsBundle(active.id, range, id);
  } catch (e) {
    data = e instanceof ApiError ? e.message : "No se pudieron cargar las métricas.";
  }

  return (
    <>
      <Button asChild variant="ghost" size="sm" className="mb-2 -ml-2">
        <Link href={`/links/${id}`}>
          <ArrowLeft /> Enlace
        </Link>
      </Button>
      <PageHeader title={`Métricas · ${link.name}`} description={active.name} />
      <DateRange basePath={`/links/${id}/stats`} value={range} />
      {typeof data === "string" ? (
        <ErrorState message={data} />
      ) : (
        <AnalyticsView data={data} emptyHint={`Escanea el QR de «${link.name}» o abre ${link.short_url} y vuelve aquí.`} />
      )}
    </>
  );
}
