import { Building2 } from "lucide-react";

import { EmptyState } from "@/components/empty-state";
import { ErrorState } from "@/components/error-state";
import { PageHeader } from "@/components/page-header";
import { OrgsTable } from "@/components/platform/orgs-table";
import { SearchForm } from "@/components/platform/search-form";
import { Button } from "@/components/ui/button";
import { ADMIN_PAGE_SIZE, ApiError, adminListOrgs, type AdminOrg } from "@/lib/api";
import Link from "next/link";

export const metadata = { title: "Consola Monky · Organizaciones" };

export default async function Page({ searchParams }: { searchParams: Promise<{ q?: string; offset?: string }> }) {
  const sp = await searchParams;
  const q = (sp.q ?? "").trim().slice(0, 120);
  const offset = Math.max(0, Number.parseInt(sp.offset ?? "0", 10) || 0);

  let orgs: AdminOrg[] = [];
  let error: string | null = null;
  try {
    orgs = await adminListOrgs(q, offset);
  } catch (e) {
    if (!(e instanceof ApiError)) throw e;
    error = e.message;
  }

  const href = (o: number) => {
    const p = new URLSearchParams();
    if (q) p.set("q", q);
    if (o > 0) p.set("offset", String(o));
    const s = p.toString();
    return s ? `/platform?${s}` : "/platform";
  };

  return (
    <>
      <PageHeader title="Organizaciones" description="Clientes, planes, límites y uso de los últimos 30 días." />
      <SearchForm q={q} placeholder="Buscar por nombre o slug…" label="Buscar organizaciones" />
      {error ? (
        <ErrorState message={error} />
      ) : orgs.length === 0 ? (
        <EmptyState icon={<Building2 />} title={q ? "Sin resultados" : "Aún no hay organizaciones"} description={q ? `Ninguna organización coincide con «${q}».` : undefined} />
      ) : (
        <>
          <OrgsTable orgs={orgs} />
          <div className="mt-4 flex justify-end gap-2">
            {offset > 0 ? (
              <Button asChild variant="outline" size="sm"><Link href={href(Math.max(0, offset - ADMIN_PAGE_SIZE))}>Anterior</Link></Button>
            ) : null}
            {orgs.length === ADMIN_PAGE_SIZE ? (
              <Button asChild variant="outline" size="sm"><Link href={href(offset + ADMIN_PAGE_SIZE)}>Siguiente</Link></Button>
            ) : null}
          </div>
        </>
      )}
    </>
  );
}
