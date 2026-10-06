import { notFound, redirect } from "next/navigation";

import { AppShell } from "@/components/layout/app-shell";
import { PlatformNav } from "@/components/platform/platform-nav";
import { ApiError, getMe, getOrgContext, type MyOrg } from "@/lib/api";
import { createClient } from "@/lib/supabase/server";

/** Consola Monky: solo platform admins. Para el resto la ruta no existe (404). */
export default async function PlatformLayout({ children }: { children: React.ReactNode }) {
  const supabase = await createClient();
  const { data } = await supabase.auth.getClaims();
  if (!data?.claims) redirect("/login");

  let isPlatformAdmin = false;
  try {
    isPlatformAdmin = (await getMe()).is_platform_admin;
  } catch (e) {
    if (!(e instanceof ApiError)) throw e;
  }
  if (!isPlatformAdmin) notFound();

  let orgs: MyOrg[] = [];
  let active: MyOrg | null = null;
  try {
    ({ orgs, active } = await getOrgContext());
  } catch {
    /* el shell funciona sin orgs */
  }

  return (
    <AppShell orgs={orgs} active={active} email={String(data.claims.email ?? "usuario")} isPlatformAdmin>
      <PlatformNav />
      {children}
    </AppShell>
  );
}
