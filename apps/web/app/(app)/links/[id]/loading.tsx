import { Skeleton } from "@/components/ui/skeleton";

export default function Loading() {
  return (
    <div role="status" aria-label="Cargando enlace" className="grid gap-4 lg:grid-cols-2">
      <Skeleton className="h-8 w-56 lg:col-span-2" />
      <Skeleton className="h-16 lg:col-span-2" />
      <Skeleton className="h-40" />
      <Skeleton className="h-40" />
      <Skeleton className="h-64" />
      <Skeleton className="h-64" />
    </div>
  );
}
