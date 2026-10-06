import Link from "next/link";

import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from "@/components/ui/table";

import { CopyButton } from "./copy-button";
import { StatusBadge } from "./status-badge";
import type { LinkItem } from "./types";

export function LinksTable({ items }: { items: LinkItem[] }) {
  return (
    <div className="rounded-xl border">
      <Table>
        <TableHeader>
          <TableRow>
            <TableHead>Nombre</TableHead>
            <TableHead>Enlace corto</TableHead>
            <TableHead>Estado</TableHead>
            <TableHead className="text-right">Escaneos 7 d</TableHead>
          </TableRow>
        </TableHeader>
        <TableBody>
          {items.map((l) => (
            <TableRow key={l.id}>
              <TableCell className="max-w-64 min-w-40">
                <Link href={`/links/${l.id}`} className="block truncate font-medium hover:underline">
                  {l.name}
                </Link>
                <span className="block truncate text-xs text-muted-foreground" title={l.destination_url}>
                  {l.destination_url}
                </span>
              </TableCell>
              <TableCell>
                <div className="flex items-center gap-1">
                  <code className="text-xs">{l.short_url.replace(/^https?:\/\//, "")}</code>
                  <CopyButton value={l.short_url} label={`Copiar enlace corto de ${l.name}`} />
                </div>
              </TableCell>
              <TableCell>
                <StatusBadge status={l.status} />
              </TableCell>
              {/* TODO(T047): mostrar escaneos de los últimos 7 días cuando exista el endpoint de stats. */}
              <TableCell className="text-right text-muted-foreground" aria-label="Sin datos todavía">
                —
              </TableCell>
            </TableRow>
          ))}
        </TableBody>
      </Table>
    </div>
  );
}
