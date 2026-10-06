"use client";

import { Bar, BarChart, CartesianGrid, Tooltip, XAxis, YAxis } from "recharts";

import { ChartFrame } from "./chart-frame";

export interface DayPoint {
  day: string;
  scans: number;
  unique: number;
}

const nf = new Intl.NumberFormat("es");
const fmtDay = (iso: string) =>
  new Date(`${iso}T00:00:00Z`).toLocaleDateString("es", { day: "numeric", month: "short", timeZone: "UTC" });

/**
 * Escaneos por día. Colores vía variables del tema (claro/oscuro). Accesible: el gráfico es
 * decorativo para lectores de pantalla (aria-hidden) y se ofrece la misma data en una tabla sr-only.
 */
export function ScansChart({ data }: { data: DayPoint[] }) {
  return (
    <figure>
      <ChartFrame className="h-64 w-full" label={`Gráfico de barras de escaneos por día, ${data.length} días`}>
        {(width, height) => (
          <BarChart width={width} height={height} data={data} margin={{ top: 8, right: 8, bottom: 0, left: -12 }}>
            <CartesianGrid vertical={false} stroke="var(--border)" />
            <XAxis
              dataKey="day"
              tickFormatter={fmtDay}
              tickLine={false}
              axisLine={false}
              minTickGap={24}
              tick={{ fill: "var(--muted-foreground)", fontSize: 12 }}
            />
            <YAxis
              allowDecimals={false}
              tickLine={false}
              axisLine={false}
              width={44}
              tick={{ fill: "var(--muted-foreground)", fontSize: 12 }}
            />
            <Tooltip
              cursor={{ fill: "var(--muted)", opacity: 0.5 }}
              content={({ active, payload }) => {
                const p = payload?.[0]?.payload as DayPoint | undefined;
                if (!active || !p) return null;
                return (
                  <div className="rounded-lg border bg-popover px-3 py-2 text-xs text-popover-foreground shadow-md">
                    <p className="font-medium">{fmtDay(p.day)}</p>
                    <p className="tabular-nums">Escaneos: {nf.format(p.scans)}</p>
                    <p className="tabular-nums">Únicos: {nf.format(p.unique)}</p>
                  </div>
                );
              }}
            />
            <Bar dataKey="scans" fill="var(--primary)" radius={[3, 3, 0, 0]} isAnimationActive={false} />
          </BarChart>
        )}
      </ChartFrame>
      <figcaption className="sr-only">Escaneos y visitantes únicos por día</figcaption>
      <table className="sr-only">
        <caption>Escaneos por día</caption>
        <thead>
          <tr>
            <th scope="col">Día</th>
            <th scope="col">Escaneos</th>
            <th scope="col">Únicos</th>
          </tr>
        </thead>
        <tbody>
          {data.map((d) => (
            <tr key={d.day}>
              <th scope="row">{d.day}</th>
              <td>{d.scans}</td>
              <td>{d.unique}</td>
            </tr>
          ))}
        </tbody>
      </table>
    </figure>
  );
}
