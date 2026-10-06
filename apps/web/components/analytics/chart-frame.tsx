"use client";

import { useEffect, useRef, useState } from "react";

import { cn } from "@/lib/utils";

/** Mide el contenedor (ResizeObserver) y entrega width/height al gráfico; evita avisos de SSR de Recharts. */
export function ChartFrame({
  className,
  label,
  children,
}: {
  className?: string;
  label: string;
  children: (width: number, height: number) => React.ReactNode;
}) {
  const ref = useRef<HTMLDivElement>(null);
  const [size, setSize] = useState<{ w: number; h: number } | null>(null);

  useEffect(() => {
    const el = ref.current;
    if (!el) return;
    const ro = new ResizeObserver(([e]) => {
      const { width, height } = e.contentRect;
      setSize({ w: Math.floor(width), h: Math.floor(height) });
    });
    ro.observe(el);
    return () => ro.disconnect();
  }, []);

  return (
    <div ref={ref} className={cn(className)} aria-hidden="true" data-label={label}>
      {size && size.w > 0 ? children(size.w, size.h) : null}
    </div>
  );
}
