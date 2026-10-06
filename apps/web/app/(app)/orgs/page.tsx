import { Building2 } from "lucide-react";

import { selectOrg } from "./actions";
import { CreateOrgDialog } from "@/components/orgs/create-org-dialog";
import { EmptyState } from "@/components/empty-state";
import { ErrorState } from "@/components/error-state";
import { PageHeader } from "@/components/page-header";
import { Badge } from "@/components/ui/badge";
import { Button } from "@/components/ui/button";
import { Card, CardContent, CardHeader, CardTitle, CardDescription } from "@/components/ui/card";
import { getActiveOrgId, listOrgs, type MyOrg } from "@/lib/api";

export const metadata = { title: "Organizaciones · Dynamic QR" };

export default async function OrgsPage() {
  let orgs: MyOrg[] = [];
  let error: string | null = null;
  try {
    orgs = await listOrgs();
  } catch (e) {
    error = e instanceof Error ? e.message : "Error desconocido";
  }
  const activeId = await getActiveOrgId();

  return (
    <>
      <PageHeader title="Organizaciones" description="Elige con cuál trabajar." actions={orgs.length ? <CreateOrgDialog /> : null} />
      {error ? (
        <ErrorState message={error} />
      ) : orgs.length === 0 ? (
        <EmptyState icon={<Building2 />} title="Aún no tienes organizaciones" description="Crea la primera para empezar a generar enlaces y QR." action={<CreateOrgDialog />} />
      ) : (
        <ul className="grid gap-4 sm:grid-cols-2 lg:grid-cols-3">
          {orgs.map((o) => (
            <li key={o.id}>
              <Card>
                <CardHeader>
                  <CardTitle className="flex items-center justify-between gap-2">
                    <span className="truncate">{o.name}</span>
                    <Badge>{o.role}</Badge>
                  </CardTitle>
                  <CardDescription>{o.slug} · plan {o.plan}</CardDescription>
                </CardHeader>
                <CardContent>
                  <form action={selectOrg}>
                    <input type="hidden" name="orgId" value={o.id} />
                    <Button type="submit" variant={o.id === activeId ? "secondary" : "default"} size="sm">
                      {o.id === activeId ? "Activa · Abrir" : "Seleccionar"}
                    </Button>
                  </form>
                </CardContent>
              </Card>
            </li>
          ))}
        </ul>
      )}
    </>
  );
}
