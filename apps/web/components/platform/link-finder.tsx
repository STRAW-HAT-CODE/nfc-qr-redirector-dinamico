"use client";

import { Link2, Loader2, Search } from "lucide-react";
import { useState, useTransition } from "react";

import { findLinkAction } from "@/app/(platform)/platform/actions";
import { EmptyState } from "@/components/empty-state";
import { ErrorState } from "@/components/error-state";
import { SuspendAction } from "@/components/platform/suspend-action";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from "@/components/ui/table";
import type { AdminLink } from "@/lib/api";

const STATUS: Record<AdminLink["status"], string> = { active: "Activo", paused: "Suspendido", archived: "Archivado" };

export function LinkFinder() {
  const [slug, setSlug] = useState("");
  const [searched, setSearched] = useState<string | null>(null);
  const [links, setLinks] = useState<AdminLink[]>([]);
  const [error, setError] = useState<string | null>(null);
  const [pending, start] = useTransition();

  function search(value = slug) {
    const s = value.trim();
    if (!s) return;
    start(async () => {
      const res = await findLinkAction(s);
      setSearched(s);
      if (res.ok) {
        setError(null);
        setLinks(res.data ?? []);
      } else {
        setError(res.message ?? "Error al buscar.");
        setLinks([]);
      }
    });
  }

  return (
    <div className="grid gap-4">
      <form role="search" className="flex gap-2" onSubmit={(e) => { e.preventDefault(); search(); }}>
        <div className="relative flex-1">
          <Search className="pointer-events-none absolute top-1/2 left-3 size-4 -translate-y-1/2 text-muted-foreground" aria-hidden="true" />
          <Input value={slug} onChange={(e) => setSlug(e.target.value)} placeholder="Slug del enlace, p. ej. promo-verano" aria-label="Slug del enlace" maxLength={64} className="pl-9 font-mono" />
        </div>
        <Button type="submit" variant="secondary" disabled={pending || !slug.trim()}>
          {pending ? <Loader2 className="animate-spin" aria-hidden="true" /> : null}
          Buscar
        </Button>
      </form>

      <div aria-live="polite">
        {error ? (
          <ErrorState message={error} />
        ) : searched === null ? (
          <EmptyState icon={<Link2 />} title="Busca un enlace" description="Encuentra cualquier enlace por su slug para suspenderlo o reactivarlo." />
        ) : links.length === 0 ? (
          <EmptyState icon={<Link2 />} title="Sin resultados" description={`No existe ningún enlace con el slug «${searched}».`} />
        ) : (
          <div className="rounded-xl border">
            <Table>
              <TableHeader>
                <TableRow>
                  <TableHead>Enlace</TableHead>
                  <TableHead>Organización</TableHead>
                  <TableHead>Estado</TableHead>
                  <TableHead><span className="sr-only">Acciones</span></TableHead>
                </TableRow>
              </TableHeader>
              <TableBody>
                {links.map((l) => (
                  <LinkRow key={l.id} link={l} onChanged={() => search(searched)} />
                ))}
              </TableBody>
            </Table>
          </div>
        )}
      </div>
    </div>
  );
}

function LinkRow({ link, onChanged }: { link: AdminLink; onChanged: () => void }) {
  return (
    <TableRow>
      <TableCell className="max-w-xs">
        <div className="font-medium">{link.name}</div>
        <div className="font-mono text-xs text-muted-foreground">/{link.slug}</div>
        <div className="truncate text-xs text-muted-foreground" title={link.destination_url}>{link.destination_url}</div>
      </TableCell>
      <TableCell>{link.org_name}</TableCell>
      <TableCell>
        <Badge variant={link.status === "active" ? "outline" : "secondary"}>{STATUS[link.status]}</Badge>
      </TableCell>
      <TableCell>
        <div className="flex justify-end">
          <SuspendAction kind="link" id={link.id} name={link.slug} suspended={link.status !== "active"} onDone={onChanged} />
        </div>
      </TableCell>
    </TableRow>
  );
}
