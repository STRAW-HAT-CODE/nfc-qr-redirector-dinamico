import { Settings } from "lucide-react";

import { EmptyState } from "@/components/empty-state";
import { PageHeader } from "@/components/page-header";
import { requireActiveOrg } from "@/lib/api";

export const metadata = { title: "Ajustes · Dynamic QR" };

export default async function Page() {
  const { active } = await requireActiveOrg();
  return (
    <>
      <PageHeader title="Ajustes" description={active.name} />
      <EmptyState icon={<Settings />} title="Ajustes de la organización" description="Esta pantalla llegará en una próxima tarea." />
    </>
  );
}
