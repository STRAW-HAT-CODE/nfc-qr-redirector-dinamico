import { Link2 } from "lucide-react";

import { EmptyState } from "@/components/empty-state";
import { PageHeader } from "@/components/page-header";
import { requireActiveOrg } from "@/lib/api";

export const metadata = { title: "Enlaces · Dynamic QR" };

export default async function Page() {
  const { active } = await requireActiveOrg();
  return (
    <>
      <PageHeader title="Enlaces" description={active.name} />
      <EmptyState icon={<Link2 />} title="Aún no hay enlaces" description="Esta pantalla llegará en una próxima tarea." />
    </>
  );
}
