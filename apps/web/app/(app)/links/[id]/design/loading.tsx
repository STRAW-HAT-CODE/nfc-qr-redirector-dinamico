import { Skeleton } from "@/components/ui/skeleton";

export default function Loading() {
  return (
    <div role="status" aria-label="Cargando diseñador de QR" className="grid gap-4 lg:grid-cols-[minmax(0,1fr)_380px]">
      <Skeleton className="h-96" />
      <Skeleton className="h-96" />
    </div>
  );
}
