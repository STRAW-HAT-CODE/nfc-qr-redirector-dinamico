import { History } from "lucide-react";

import type { HistoryItem } from "./types";

const fmt = new Intl.DateTimeFormat("es", { dateStyle: "medium", timeStyle: "short", timeZone: "UTC" });

export function HistoryList({ items, hasMore }: { items: HistoryItem[]; hasMore: boolean }) {
  if (items.length === 0) {
    return (
      <p className="flex items-center gap-2 text-sm text-muted-foreground">
        <History className="size-4" aria-hidden="true" /> Aún no se ha cambiado el destino.
      </p>
    );
  }
  return (
    <>
      <ol className="grid gap-3">
        {items.map((h) => (
          <li key={h.id} className="rounded-lg border p-3 text-sm">
            <time dateTime={h.changed_at} className="text-xs text-muted-foreground">
              {fmt.format(new Date(h.changed_at))} UTC
            </time>
            <p className="mt-1 break-all text-muted-foreground line-through">{h.old_url}</p>
            <p className="break-all">{h.new_url}</p>
          </li>
        ))}
      </ol>
      {hasMore ? <p className="mt-2 text-xs text-muted-foreground">Mostrando los 20 cambios más recientes.</p> : null}
    </>
  );
}
