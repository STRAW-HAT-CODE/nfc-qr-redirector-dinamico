import { Link2, Plus } from "lucide-react";
import Link from "next/link";

import { EmptyState } from "@/components/empty-state";
import { ErrorState } from "@/components/error-state";
import { LinksFilters } from "@/components/links/links-filters";
import { LinksTable } from "@/components/links/links-table";
import type { LinkStatus } from "@/components/links/types";
import { PageHeader } from "@/components/page-header";
import { Button } from "@/components/ui/button";
import { ApiError, hasRole, requireActiveOrg } from "@/lib/api";

import { listLinks, PAGE_SIZE } from "./data";

export const metadata = { title: "Enlaces · Dynamic QR" };

const STATUSES = ["active", "paused", "archived"];
type SP = Promise<{ q?: string; status?: string; offset?: string }>;

export default async function Page({ searchParams }: { searchParams: SP }) {
  const sp = await searchParams;
  const { active } = await requireActiveOrg();
  const canCreate = hasRole(active.role, "editor");
  const q = (sp.q ?? "").slice(0, 120);
  const status = STATUSES.includes(sp.status ?? "") ? (sp.status as LinkStatus) : undefined;
  const offset = Math.max(0, Number.parseInt(sp.offset ?? "0", 10) || 0);

  const newButton = canCreate ? (
    <Button asChild>
      <Link href="/links/new">
        <Plus /> Crear enlace
      </Link>
    </Button>
  ) : null;

  let page;
  try {
    page = await listLinks({ q: q || undefined, status, offset });
  } catch (e) {
    return (
      <>
        <PageHeader title="Enlaces" description={active.name} actions={newButton} />
        <ErrorState message={e instanceof ApiError ? e.message : "No se pudieron cargar los enlaces."} />
      </>
    );
  }

  const filtered = Boolean(q || status);
  const href = (o: number) => {
    const p = new URLSearchParams();
    if (q) p.set("q", q);
    if (status) p.set("status", status);
    if (o > 0) p.set("offset", String(o));
    const s = p.toString();
    return s ? `/links?${s}` : "/links";
  };

  return (
    <>
      <PageHeader title="Enlaces" description={active.name} actions={newButton} />
      {page.items.length === 0 && !filtered && offset === 0 ? (
        <EmptyState
          icon={<Link2 />}
          title="Aún no hay enlaces"
          description={
            canCreate
              ? "Crea tu primer enlace dinámico: podrás cambiar su destino sin reimprimir el QR."
              : "Cuando un editor cree enlaces aparecerán aquí."
          }
          action={newButton}
        />
      ) : (
        <>
          <LinksFilters q={q} status={status ?? ""} />
          {page.items.length === 0 ? (
            <EmptyState icon={<Link2 />} title="Sin resultados" description="Ningún enlace coincide con los filtros." />
          ) : (
            <LinksTable items={page.items} />
          )}
          {offset > 0 || page.has_more ? (
            <nav aria-label="Paginación" className="mt-4 flex items-center justify-between">
              {offset > 0 ? (
                <Button asChild variant="outline" size="sm">
                  <Link href={href(Math.max(0, offset - PAGE_SIZE))}>Anterior</Link>
                </Button>
              ) : (
                <span />
              )}
              <span className="text-xs text-muted-foreground">
                {offset + 1}–{offset + page.items.length}
              </span>
              {page.has_more ? (
                <Button asChild variant="outline" size="sm">
                  <Link href={href(offset + PAGE_SIZE)}>Siguiente</Link>
                </Button>
              ) : (
                <span />
              )}
            </nav>
          ) : null}
        </>
      )}
    </>
  );
}
