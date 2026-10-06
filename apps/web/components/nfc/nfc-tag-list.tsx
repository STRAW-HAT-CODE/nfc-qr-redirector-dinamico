import { Nfc } from "lucide-react";

import { EmptyState } from "@/components/empty-state";
import { Badge } from "@/components/ui/badge";
import { Card, CardContent } from "@/components/ui/card";
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from "@/components/ui/table";
import { DeleteTagButton } from "./delete-tag-button";
import { NdefUrlCopy } from "./ndef-url-copy";
import { TagDialog } from "./tag-dialog";
import type { NfcTag } from "./types";

function BytesBadge({ tag }: { tag: NfcTag }) {
  return (
    <div className="grid gap-1">
      <span className="text-xs tabular-nums text-muted-foreground">{tag.ndef_bytes} bytes</span>
      {tag.ndef_fits ? (
        <Badge variant="secondary">Cabe en NTAG213</Badge>
      ) : (
        <Badge variant="outline" className="border-destructive text-destructive">No cabe en NTAG213</Badge>
      )}
      {tag.ndef_warning ? <p className="max-w-52 text-xs text-destructive">{tag.ndef_warning}</p> : null}
    </div>
  );
}

export function NfcTagList({
  linkId, tags, canEdit, canDelete,
}: { linkId: string; tags: NfcTag[]; canEdit: boolean; canDelete: boolean }) {
  if (tags.length === 0) {
    return (
      <EmptyState
        icon={<Nfc />}
        title="Aún no hay etiquetas NFC"
        description={
          canEdit
            ? "Crea una etiqueta por cada chip para saber en qué ubicación se escanea."
            : "Un editor puede crear etiquetas NFC para este enlace."
        }
        action={canEdit ? <TagDialog linkId={linkId} /> : undefined}
      />
    );
  }
  const showActions = canEdit || canDelete;
  return (
    <Card>
      <CardContent className="pt-6">
        <Table>
          <TableHeader>
            <TableRow>
              <TableHead>Etiqueta</TableHead>
              <TableHead>Ubicación</TableHead>
              <TableHead>UID</TableHead>
              <TableHead>URL NDEF</TableHead>
              <TableHead>Tamaño</TableHead>
              {showActions ? <TableHead className="text-right">Acciones</TableHead> : null}
            </TableRow>
          </TableHeader>
          <TableBody>
            {tags.map((t) => (
              <TableRow key={t.id}>
                <TableCell className="font-medium">{t.label}</TableCell>
                <TableCell>{t.location ?? <span className="text-muted-foreground">—</span>}</TableCell>
                <TableCell className="font-mono text-xs">{t.uid ?? <span className="text-muted-foreground">—</span>}</TableCell>
                <TableCell className="max-w-72"><NdefUrlCopy url={t.ndef_url} /></TableCell>
                <TableCell><BytesBadge tag={t} /></TableCell>
                {showActions ? (
                  <TableCell className="text-right">
                    <div className="flex justify-end gap-1">
                      {canEdit ? <TagDialog linkId={linkId} tag={t} /> : null}
                      {canDelete ? <DeleteTagButton linkId={linkId} tag={t} /> : null}
                    </div>
                  </TableCell>
                ) : null}
              </TableRow>
            ))}
          </TableBody>
        </Table>
      </CardContent>
    </Card>
  );
}
