import { Skeleton } from "@/components/ui/skeleton";

export default function Loading() {
  return (
    <div role="status" aria-label="Cargando etiquetas NFC" className="grid gap-4">
      <Skeleton className="h-8 w-56" />
      <Skeleton className="h-56" />
      <Skeleton className="h-40" />
    </div>
  );
}
