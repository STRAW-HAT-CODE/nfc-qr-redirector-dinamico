import { ChevronRight, Users } from "lucide-react";
import Link from "next/link";

import { PageHeader } from "@/components/page-header";
import { Badge } from "@/components/ui/badge";
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from "@/components/ui/card";
import { hasRole, requireActiveOrg } from "@/lib/api";

export const metadata = { title: "Ajustes · Dynamic QR" };

export default async function Page() {
  const { active } = await requireActiveOrg();
  const rows: [string, React.ReactNode][] = [
    ["Nombre", active.name],
    ["Slug", <code key="s" className="font-mono text-sm">{active.slug}</code>],
    ["Plan", <Badge key="p" variant="secondary" className="capitalize">{active.plan}</Badge>],
  ];
  return (
    <>
      <PageHeader title="Ajustes" description="Organización activa" />
      <div className="grid max-w-2xl gap-4">
        <Card>
          <CardHeader>
            <CardTitle>Organización</CardTitle>
            <CardDescription>Datos de la organización activa.</CardDescription>
          </CardHeader>
          <CardContent>
            <dl className="grid gap-3 sm:grid-cols-[8rem_1fr]">
              {rows.map(([k, v]) => (
                <div key={k} className="contents">
                  <dt className="text-sm text-muted-foreground">{k}</dt>
                  <dd>{v}</dd>
                </div>
              ))}
            </dl>
          </CardContent>
        </Card>
        {hasRole(active.role, "admin") ? (
          <Link
            href="/settings/members"
            className="flex items-center justify-between rounded-xl border p-4 transition-colors hover:bg-muted focus-visible:outline-2 focus-visible:outline-ring"
          >
            <span className="flex items-center gap-3">
              <Users className="size-5 text-muted-foreground" aria-hidden="true" />
              <span>
                <span className="block font-medium">Miembros</span>
                <span className="block text-sm text-muted-foreground">Gestiona quién tiene acceso y con qué rol.</span>
              </span>
            </span>
            <ChevronRight className="size-4 text-muted-foreground" aria-hidden="true" />
          </Link>
        ) : null}
      </div>
    </>
  );
}
