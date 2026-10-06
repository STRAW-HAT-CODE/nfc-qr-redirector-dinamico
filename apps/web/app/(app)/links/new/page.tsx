import { redirect } from "next/navigation";

import { LinkForm } from "@/components/links/link-form";
import { PageHeader } from "@/components/page-header";
import { hasRole, requireActiveOrg } from "@/lib/api";

export const metadata = { title: "Crear enlace · Dynamic QR" };

export default async function Page() {
  const { active } = await requireActiveOrg();
  if (!hasRole(active.role, "editor")) redirect("/links");
  return (
    <>
      <PageHeader title="Crear enlace" description={active.name} />
      <LinkForm />
    </>
  );
}
