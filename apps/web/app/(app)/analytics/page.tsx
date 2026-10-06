import { BarChart3 } from "lucide-react";

import { EmptyState } from "@/components/empty-state";
import { PageHeader } from "@/components/page-header";
import { requireActiveOrg } from "@/lib/api";

export const metadata = { title: "Analytics · Dynamic QR" };

export default async function Page() {
  const { active } = await requireActiveOrg();
  return (
    <>
      <PageHeader title="Analytics" description={active.name} />
      <EmptyState icon={<BarChart3 />} title="Sin métricas todavía" description="Esta pantalla llegará en una próxima tarea." />
    </>
  );
}
