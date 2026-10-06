import { QrCode } from "lucide-react";
import Link from "next/link";

import { MobileNav } from "@/components/layout/mobile-nav";
import { OrgSwitcher } from "@/components/layout/org-switcher";
import { SidebarNav } from "@/components/layout/sidebar-nav";
import { UserMenu } from "@/components/layout/user-menu";
import type { MyOrg } from "@/lib/api";

function SidebarContent({
  orgs,
  active,
  email,
  isAdmin,
  isPlatformAdmin,
}: {
  orgs: MyOrg[];
  active: MyOrg | null;
  email: string;
  isAdmin: boolean;
  isPlatformAdmin: boolean;
}) {
  return (
    <div className="flex h-full flex-col gap-4 p-3">
      <Link href="/orgs" className="flex items-center gap-2 px-2 py-1 font-semibold">
        <QrCode className="size-5 text-primary" aria-hidden="true" />
        Dynamic QR
      </Link>
      <OrgSwitcher orgs={orgs} active={active} />
      <SidebarNav isAdmin={isAdmin} />
      <div className="mt-auto border-t pt-3">
        <UserMenu email={email} isPlatformAdmin={isPlatformAdmin} />
      </div>
    </div>
  );
}

export function AppShell({
  orgs,
  active,
  email,
  isPlatformAdmin = false,
  children,
}: {
  orgs: MyOrg[];
  active: MyOrg | null;
  email: string;
  isPlatformAdmin?: boolean;
  children: React.ReactNode;
}) {
  const isAdmin = active?.role === "admin" || active?.role === "owner";
  const props = { orgs, active, email, isAdmin, isPlatformAdmin };
  return (
    <div className="flex min-h-dvh">
      <aside className="sticky top-0 hidden h-dvh w-64 shrink-0 border-r bg-sidebar text-sidebar-foreground md:block">
        <SidebarContent {...props} />
      </aside>
      <div className="flex min-w-0 flex-1 flex-col">
        <header className="flex items-center gap-2 border-b bg-background px-4 py-2 md:hidden">
          <MobileNav>
            <SidebarContent {...props} />
          </MobileNav>
          <span className="flex items-center gap-2 font-semibold">
            <QrCode className="size-5 text-primary" aria-hidden="true" />
            Dynamic QR
          </span>
        </header>
        <main id="main" className="mx-auto w-full max-w-6xl flex-1 px-4 py-6 md:px-8 md:py-8">
          {children}
        </main>
      </div>
    </div>
  );
}
