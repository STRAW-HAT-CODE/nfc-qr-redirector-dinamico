import { ArrowLeft, BarChart3, Nfc, QrCode } from "lucide-react";
import Link from "next/link";
import { notFound } from "next/navigation";

import { ErrorState } from "@/components/error-state";
import { CopyButton } from "@/components/links/copy-button";
import { DeleteLinkZone } from "@/components/links/delete-link-zone";
import { DestinationEditor } from "@/components/links/destination-editor";
import { HistoryList } from "@/components/links/history-list";
import { LinkEditForm } from "@/components/links/link-edit-form";
import { StatusBadge } from "@/components/links/status-badge";
import { StatusToggle } from "@/components/links/status-toggle";
import { PageHeader } from "@/components/page-header";
import { Button } from "@/components/ui/button";
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";
import { ApiError, hasRole, requireActiveOrg } from "@/lib/api";

import { getHistory, getLink } from "../data";

export const metadata = { title: "Enlace · Dynamic QR" };

export default async function Page({ params }: { params: Promise<{ id: string }> }) {
  const { id } = await params;
  const { active } = await requireActiveOrg();
  const canEdit = hasRole(active.role, "editor");
  const canArchive = hasRole(active.role, "admin");

  let link;
  try {
    link = await getLink(id);
  } catch (e) {
    if (e instanceof ApiError && (e.status === 404 || e.status === 422)) notFound();
    return <ErrorState message={e instanceof ApiError ? e.message : "No se pudo cargar el enlace."} />;
  }
  const history = await getHistory(id).catch(() => null);
  const archived = link.status === "archived";

  return (
    <>
      <Button asChild variant="ghost" size="sm" className="mb-2 -ml-2">
        <Link href="/links">
          <ArrowLeft /> Enlaces
        </Link>
      </Button>
      <PageHeader
        title={link.name}
        description={active.name}
        actions={
          <>
            {canEdit ? (
              <Button asChild variant="outline">
                <Link href={`/links/${link.id}/design`}>
                  <QrCode /> Diseñar QR
                </Link>
              </Button>
            ) : null}
            <Button asChild variant="outline">
              <Link href={`/links/${link.id}/stats`}>
                <BarChart3 /> Métricas
              </Link>
            </Button>
            <Button asChild variant="outline">
              <Link href={`/links/${link.id}/nfc`}>
                <Nfc /> NFC
              </Link>
            </Button>
          </>
        }
      />
      <div className="grid gap-6 lg:grid-cols-2">
        <Card className="lg:col-span-2">
          <CardContent className="flex flex-wrap items-center gap-3 pt-6">
            <StatusBadge status={link.status} />
            <code className="min-w-0 flex-1 truncate text-sm">{link.short_url}</code>
            <CopyButton value={link.short_url} />
          </CardContent>
        </Card>

        <Card>
          <CardHeader>
            <CardTitle>Destino</CardTitle>
          </CardHeader>
          <CardContent>
            <DestinationEditor linkId={link.id} current={link.destination_url} canEdit={canEdit && !archived} />
          </CardContent>
        </Card>

        <Card>
          <CardHeader>
            <CardTitle>Estado</CardTitle>
          </CardHeader>
          <CardContent>
            <StatusToggle linkId={link.id} status={link.status} canEdit={canEdit} canArchive={canArchive} />
          </CardContent>
        </Card>

        <Card>
          <CardHeader>
            <CardTitle>Detalles y vigencia</CardTitle>
          </CardHeader>
          <CardContent>
            <LinkEditForm link={link} canEdit={canEdit && !archived} />
          </CardContent>
        </Card>

        <Card>
          <CardHeader>
            <CardTitle>Historial de destinos</CardTitle>
          </CardHeader>
          <CardContent>
            {history ? (
              <HistoryList items={history.items} hasMore={history.has_more} />
            ) : (
              <ErrorState title="Sin historial" message="No se pudo cargar el historial." />
            )}
          </CardContent>
        </Card>

        {canArchive ? <DeleteLinkZone linkId={link.id} linkName={link.name} /> : null}
      </div>
    </>
  );
}
