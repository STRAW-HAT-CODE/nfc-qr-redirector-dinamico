"use client";

import { BarChart3, Link2, Settings, Users } from "lucide-react";
import Link from "next/link";
import { usePathname } from "next/navigation";

import { cn } from "@/lib/utils";

const ITEMS = [
  { href: "/links", label: "Enlaces", Icon: Link2, adminOnly: false },
  { href: "/analytics", label: "Analytics", Icon: BarChart3, adminOnly: false },
  { href: "/settings/members", label: "Miembros", Icon: Users, adminOnly: true },
  { href: "/settings", label: "Ajustes", Icon: Settings, adminOnly: false, exact: true },
] as const;

export function SidebarNav({ isAdmin, onNavigate }: { isAdmin: boolean; onNavigate?: () => void }) {
  const pathname = usePathname();
  return (
    <nav aria-label="Principal" className="flex flex-col gap-1">
      {ITEMS.filter((i) => isAdmin || !i.adminOnly).map((item) => {
        const active =
          "exact" in item && item.exact
            ? pathname === item.href
            : pathname === item.href || pathname.startsWith(`${item.href}/`);
        return (
          <Link
            key={item.href}
            href={item.href}
            onClick={onNavigate}
            aria-current={active ? "page" : undefined}
            className={cn(
              "flex items-center gap-2 rounded-md px-3 py-2 text-sm font-medium transition-colors hover:bg-accent hover:text-accent-foreground",
              active && "bg-accent text-accent-foreground",
            )}
          >
            <item.Icon className="size-4" aria-hidden="true" />
            {item.label}
          </Link>
        );
      })}
    </nav>
  );
}
