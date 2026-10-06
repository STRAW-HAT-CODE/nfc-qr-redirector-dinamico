import { Users } from "lucide-react";

import { EmptyState } from "@/components/empty-state";
import { PageHeader } from "@/components/page-header";
import { requireActiveOrg, hasRole } from "@/lib/api";

export const metadata = { title: "Miembros · Dynamic QR" };

export default async function Page() {
  const { active } = await requireActiveOrg();
  if (!hasRole(active.role, "admin")) {
    return <EmptyState icon={<Users />} title="Sin permiso" description="Solo administradores pueden gestionar miembros." />;
  }
  return (
    <>
      <PageHeader title="Miembros" description={active.name} />
      <EmptyState icon={<Users />} title="Gestión de miembros" description="Esta pantalla llegará en una próxima tarea." />
    </>
  );
}
