import { PageHeader } from "@/components/page-header";
import { LinkFinder } from "@/components/platform/link-finder";

export const metadata = { title: "Consola Monky · Enlaces" };

export default function Page() {
  return (
    <>
      <PageHeader title="Enlaces" description="Busca un enlace por slug y suspéndelo ante un abuso." />
      <LinkFinder />
    </>
  );
}
