import { FileText, Monitor, Star, Sticker } from "lucide-react";

import { Badge } from "@/components/ui/badge";
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from "@/components/ui/card";

/** Plantillas de impresión (T033). Hasta que la API las exponga se muestran como "próximamente". */
export const TEMPLATES = [
  { id: "sticker", name: "Sticker", icon: Sticker },
  { id: "display", name: "Display", icon: Monitor },
  { id: "poster", name: "Póster A4", icon: FileText },
  { id: "google_review", name: "Reseña en Google", icon: Star },
] as const;

export function TemplatesGallery() {
  return (
    <Card>
      <CardHeader>
        <CardTitle>Plantillas de impresión</CardTitle>
        <CardDescription>Sticker / Display / Póster A4 / Reseña en Google: próximamente.</CardDescription>
      </CardHeader>
      <CardContent>
        <ul className="grid grid-cols-2 sm:grid-cols-4 gap-3">
          {TEMPLATES.map(({ id, name, icon: Icon }) => (
            <li key={id} className="flex flex-col items-center gap-2 rounded-lg border border-dashed p-3 text-center opacity-70">
              <Icon className="size-6 text-muted-foreground" aria-hidden="true" />
              <span className="text-sm font-medium">{name}</span>
              <Badge variant="secondary">Próximamente</Badge>
            </li>
          ))}
        </ul>
      </CardContent>
    </Card>
  );
}
