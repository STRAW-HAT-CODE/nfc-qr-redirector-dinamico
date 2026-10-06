import { PlanEditor } from "@/components/platform/plan-editor";
import { SuspendAction } from "@/components/platform/suspend-action";
import { Badge } from "@/components/ui/badge";
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from "@/components/ui/table";
import type { AdminOrg } from "@/lib/api";

const num = new Intl.NumberFormat("es");

export function OrgsTable({ orgs }: { orgs: AdminOrg[] }) {
  return (
    <div className="rounded-xl border">
      <Table>
        <TableHeader>
          <TableRow>
            <TableHead>Organización</TableHead>
            <TableHead>Plan</TableHead>
            <TableHead>Estado</TableHead>
            <TableHead className="text-right">Miembros</TableHead>
            <TableHead className="text-right">Enlaces</TableHead>
            <TableHead className="hidden text-right md:table-cell">Escaneos 30 d</TableHead>
            <TableHead><span className="sr-only">Acciones</span></TableHead>
          </TableRow>
        </TableHeader>
        <TableBody>
          {orgs.map((o) => (
            <TableRow key={o.id}>
              <TableCell>
                <div className="font-medium">{o.name}</div>
                <div className="font-mono text-xs text-muted-foreground">{o.slug}</div>
              </TableCell>
              <TableCell>
                <Badge variant="secondary" className="capitalize">{o.plan}</Badge>
                {o.limits && Object.keys(o.limits).length > 0 ? (
                  <Badge variant="outline" className="ml-1">override</Badge>
                ) : null}
              </TableCell>
              <TableCell>
                {o.status === "suspended" ? <Badge variant="outline" className="border-destructive/30 bg-destructive/10 text-destructive">Suspendida</Badge> : <Badge variant="outline">Activa</Badge>}
              </TableCell>
              <TableCell className="text-right tabular-nums">{num.format(o.members)}</TableCell>
              <TableCell className="text-right tabular-nums">{num.format(o.links)}</TableCell>
              <TableCell className="hidden text-right tabular-nums md:table-cell">{num.format(o.scans_30d)}</TableCell>
              <TableCell>
                <div className="flex justify-end gap-1">
                  <PlanEditor org={o} />
                  <SuspendAction kind="org" id={o.id} name={o.name} suspended={o.status === "suspended"} />
                </div>
              </TableCell>
            </TableRow>
          ))}
        </TableBody>
      </Table>
    </div>
  );
}
