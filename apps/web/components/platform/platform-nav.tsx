"use client";

import Link from "next/link";
import { usePathname } from "next/navigation";

import { cn } from "@/lib/utils";

const TABS = [
  { href: "/platform", label: "Organizaciones", exact: true },
  { href: "/platform/links", label: "Enlaces", exact: false },
  { href: "/platform/domains", label: "Dominios bloqueados", exact: false },
] as const;

export function PlatformNav() {
  const pathname = usePathname();
  return (
    <nav aria-label="Consola Monky" className="mb-6 flex gap-1 overflow-x-auto border-b">
      {TABS.map((t) => {
        const active = t.exact ? pathname === t.href : pathname.startsWith(t.href);
        return (
          <Link
            key={t.href}
            href={t.href}
            aria-current={active ? "page" : undefined}
            className={cn(
              "-mb-px shrink-0 border-b-2 px-3 py-2 text-sm font-medium focus-visible:outline-2 focus-visible:outline-ring",
              active ? "border-primary text-foreground" : "border-transparent text-muted-foreground hover:text-foreground",
            )}
          >
            {t.label}
          </Link>
        );
      })}
    </nav>
  );
}
