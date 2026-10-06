import { ScanLine, Users } from "lucide-react";

import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";

const nf = new Intl.NumberFormat("es");

export function KpiCards({ scans, unique }: { scans: number; unique: number }) {
  const items = [
    { label: "Escaneos", value: scans, icon: <ScanLine />, hint: "Total en el rango" },
    { label: "Visitantes únicos", value: unique, icon: <Users />, hint: "Suma de únicos diarios" },
  ];
  return (
    <div className="mb-6 grid gap-4 sm:grid-cols-2">
      {items.map((i) => (
        <Card key={i.label} role="group" aria-label={`${i.label}: ${nf.format(i.value)}`}>
          <CardHeader className="flex-row items-center justify-between">
            <CardTitle className="text-sm font-medium text-muted-foreground">{i.label}</CardTitle>
            <span className="text-muted-foreground [&_svg]:size-4" aria-hidden="true">
              {i.icon}
            </span>
          </CardHeader>
          <CardContent>
            <p className="text-3xl font-semibold tabular-nums">{nf.format(i.value)}</p>
            <p className="mt-1 text-xs text-muted-foreground">{i.hint}</p>
          </CardContent>
        </Card>
      ))}
    </div>
  );
}
