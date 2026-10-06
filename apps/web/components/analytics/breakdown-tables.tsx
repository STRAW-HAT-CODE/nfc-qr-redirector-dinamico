import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from "@/components/ui/table";
import { topWithOthers, type Row } from "@/lib/stats-range";

const nf = new Intl.NumberFormat("es");
const pf = new Intl.NumberFormat("es", { style: "percent", maximumFractionDigits: 0 });

const CHANNELS: Record<string, string> = { qr: "Código QR", nfc: "Etiqueta NFC", direct: "Enlace directo" };

function countryName(code: string) {
  try {
    return new Intl.DisplayNames(["es"], { type: "region" }).of(code.toUpperCase()) ?? code;
  } catch {
    return code;
  }
}

const labelers = {
  channel: (k: string) => CHANNELS[k] ?? k,
  country: (k: string) => countryName(k),
  device: (k: string) => k,
} as const;

function label(kind: keyof typeof labelers, key: string) {
  if (key === "other") return "Otros";
  if (key === "unknown") return "Desconocido";
  return labelers[kind](key);
}

function Breakdown({ title, kind, rows }: { title: string; kind: keyof typeof labelers; rows: Row[] }) {
  const top = topWithOthers(rows);
  const total = top.reduce((s, r) => s + r.scans, 0);
  return (
    <Card>
      <CardHeader>
        <CardTitle>{title}</CardTitle>
      </CardHeader>
      <CardContent>
        {top.length === 0 ? (
          <p className="text-sm text-muted-foreground">Sin datos en este rango.</p>
        ) : (
          <Table>
            <TableHeader>
              <TableRow>
                <TableHead>{title.replace("Por ", "")}</TableHead>
                <TableHead className="text-right">Escaneos</TableHead>
                <TableHead className="w-16 text-right">%</TableHead>
              </TableRow>
            </TableHeader>
            <TableBody>
              {top.map((r) => (
                <TableRow key={r.key}>
                  <TableCell className="max-w-40 truncate">{label(kind, r.key)}</TableCell>
                  <TableCell className="text-right tabular-nums">{nf.format(r.scans)}</TableCell>
                  <TableCell className="text-right text-muted-foreground tabular-nums">
                    {pf.format(total ? r.scans / total : 0)}
                  </TableCell>
                </TableRow>
              ))}
            </TableBody>
          </Table>
        )}
      </CardContent>
    </Card>
  );
}

export function BreakdownTables({ channel, country, device }: { channel: Row[]; country: Row[]; device: Row[] }) {
  return (
    <div className="grid gap-6 lg:grid-cols-3">
      <Breakdown title="Por canal" kind="channel" rows={channel} />
      <Breakdown title="Por país" kind="country" rows={country} />
      <Breakdown title="Por dispositivo" kind="device" rows={device} />
    </div>
  );
}
