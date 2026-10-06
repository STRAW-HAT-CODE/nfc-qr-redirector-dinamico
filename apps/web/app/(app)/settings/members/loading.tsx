import { Skeleton } from "@/components/ui/skeleton";

export default function Loading() {
  return (
    <div role="status" aria-label="Cargando miembros" className="grid gap-3">
      <Skeleton className="h-8 w-48" />
      {Array.from({ length: 4 }).map((_, i) => <Skeleton key={i} className="h-12 w-full" />)}
    </div>
  );
}
