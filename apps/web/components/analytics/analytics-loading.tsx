import { Skeleton } from "@/components/ui/skeleton";

export function AnalyticsLoading() {
  return (
    <div role="status" aria-label="Cargando métricas" className="grid gap-4">
      <Skeleton className="h-8 w-72" />
      <div className="grid gap-4 sm:grid-cols-2">
        <Skeleton className="h-28" />
        <Skeleton className="h-28" />
      </div>
      <Skeleton className="h-80" />
      <div className="grid gap-4 lg:grid-cols-3">
        <Skeleton className="h-48" />
        <Skeleton className="h-48" />
        <Skeleton className="h-48" />
      </div>
    </div>
  );
}
