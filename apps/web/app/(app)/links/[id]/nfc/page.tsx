import { ArrowLeft, Nfc } from "lucide-react";
import Link from "next/link";
import { notFound } from "next/navigation";

import { ErrorState } from "@/components/error-state";
import { NfcTagList } from "@/components/nfc/nfc-tag-list";
import { TagDialog } from "@/components/nfc/tag-dialog";
import { WriteGuide } from "@/components/nfc/write-guide";
import type { NfcTag, NfcTagList as NfcTagListResponse } from "@/components/nfc/types";
import { PageHeader } from "@/components/page-header";
import { Button } from "@/components/ui/button";
import { api, ApiError, hasRole, requireActiveOrg } from "@/lib/api";

export const metadata = { title: "Etiquetas NFC · Dynamic QR" };

export default async function Page({ params }: { params: Promise<{ id: string }> }) {
  const { id } = await params;
  const { active } = await requireActiveOrg();
  const canEdit = hasRole(active.role, "editor");
  const canDelete = hasRole(active.role, "admin");

  let tags: NfcTag[];
  try {
    tags = (await api<NfcTagListResponse>(`/v1/links/${encodeURIComponent(id)}/nfc-tags`)).items;
  } catch (e) {
    if (e instanceof ApiError && (e.status === 404 || e.status === 422)) notFound();
    return (
      <ErrorState
        message={e instanceof ApiError ? e.message : "No se pudieron cargar las etiquetas NFC."}
        action={
          <Button asChild variant="outline" size="sm">
            <Link href={`/links/${id}`}>Volver al enlace</Link>
          </Button>
        }
      />
    );
  }

  return (
    <>
      <Button asChild variant="ghost" size="sm" className="mb-2 -ml-2">
        <Link href={`/links/${id}`}>
          <ArrowLeft /> Enlace
        </Link>
      </Button>
      <PageHeader
        title="Etiquetas NFC"
        description="Cada chip lleva su propia URL NDEF para medir en qué ubicación se escanea."
        actions={canEdit ? <TagDialog linkId={id} /> : null}
      />
      <div className="grid gap-6">
        <NfcTagList linkId={id} tags={tags} canEdit={canEdit} canDelete={canDelete} />
        <section aria-labelledby="guide-title">
          <h2 id="guide-title" className="mb-3 flex items-center gap-2 text-lg font-semibold">
            <Nfc className="size-5" aria-hidden="true" /> Cómo grabar una etiqueta
          </h2>
          <WriteGuide />
        </section>
      </div>
    </>
  );
}
