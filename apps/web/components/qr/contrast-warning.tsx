import { TriangleAlert } from "lucide-react";

import { Alert, AlertDescription, AlertTitle } from "@/components/ui/alert";
import { contrastWarnings } from "@/lib/qr-contrast";

/** Avisos de la API (X-QR-Warnings / warnings del diseño) + cálculo local de contraste. */
export function ContrastWarning({ fg, bg, transparent, serverWarnings }: { fg: string; bg: string; transparent?: boolean; serverWarnings: string[] }) {
  const all = [...new Set([
    ...contrastWarnings(fg, transparent ? "#ffffff" : bg),
    ...(transparent ? ["Fondo transparente: colócalo sobre una superficie clara"] : []),
    ...serverWarnings,
  ])];
  if (!all.length) return null;
  return (
    <Alert>
      <TriangleAlert />
      <AlertTitle>Revisa la legibilidad</AlertTitle>
      <AlertDescription>
        <ul className="list-disc pl-4">
          {all.map((w) => (
            <li key={w}>{w}</li>
          ))}
        </ul>
      </AlertDescription>
    </Alert>
  );
}
