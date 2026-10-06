import { ArrowLeft } from "lucide-react";
import Link from "next/link";
import { notFound } from "next/navigation";

import { ErrorState } from "@/components/error-state";
import { PageHeader } from "@/components/page-header";
import { QrDesigner } from "@/components/qr/qr-designer";
import { Button } from "@/components/ui/button";
import { ApiError, getQrDesign, hasRole, requireActiveOrg } from "@/lib/api";

import { getLink } from "../../data";

export const metadata = { title: "Diseñador de QR · Dynamic QR" };

export default async function Page({ params }: { params: Promise<{ id: string }> }) {
  const { id } = await params;
  const { active } = await requireActiveOrg();
  const canEdit = hasRole(active.role, "editor");

  let data;
  try {
    const [link, design] = await Promise.all([getLink(id), getQrDesign(id)]);
    data = { link, design };
  } catch (e) {
    if (e instanceof ApiError && (e.status === 404 || e.status === 422)) notFound();
    return (
      <ErrorState
        message={e instanceof ApiError ? e.message : "No se pudo cargar el diseño."}
        action={
          <Button asChild variant="outline" size="sm">
            <Link href={`/links/${id}`}>Volver al enlace</Link>
          </Button>
        }
      />
    );
  }
  const { link, design } = data;

  return (
    <>
      <Button asChild variant="ghost" size="sm" className="mb-2 -ml-2">
        <Link href={`/links/${id}`}>
          <ArrowLeft /> Enlace
        </Link>
      </Button>
      <PageHeader
        title="Diseñador de QR"
        description={canEdit ? link.name : `${link.name} · solo lectura: puedes ver y descargar`}
      />
      <QrDesigner linkId={id} shortUrl={link.short_url} initial={design} canEdit={canEdit} />
    </>
  );
}
