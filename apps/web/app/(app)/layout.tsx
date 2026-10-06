import { redirect } from "next/navigation";

import { AppShell } from "@/components/layout/app-shell";
import { ErrorState } from "@/components/error-state";
import { getMe, getOrgContext, type MyOrg } from "@/lib/api";
import { createClient } from "@/lib/supabase/server";

export default async function AppLayout({ children }: { children: React.ReactNode }) {
  const supabase = await createClient();
  const { data } = await supabase.auth.getClaims();
  if (!data?.claims) redirect("/login");
  const email = String(data.claims.email ?? "usuario");

  let orgs: MyOrg[] = [];
  let active: MyOrg | null = null;
  let failed = false;
  try {
    ({ orgs, active } = await getOrgContext());
  } catch {
    failed = true;
  }

  // Solo decide si se muestra el enlace; la autorización real la hace la API.
  const isPlatformAdmin = await getMe().then((m) => m.is_platform_admin, () => false);

  return (
    <AppShell orgs={orgs} active={active} email={email} isPlatformAdmin={isPlatformAdmin}>
      {failed ? (
        <ErrorState message="No se pudo cargar tus organizaciones. Verifica la conexión con la API y recarga." />
      ) : (
        children
      )}
    </AppShell>
  );
}
