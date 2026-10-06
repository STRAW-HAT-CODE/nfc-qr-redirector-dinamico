"use client";

import { QrCode } from "lucide-react";
import qrcode from "qrcode-generator";
import { useMemo, useState } from "react";

import { CopyButton } from "@/components/links/copy-button";
import { Button } from "@/components/ui/button";

function QrSvg({ value }: { value: string }) {
  const svg = useMemo(() => {
    const qr = qrcode(0, "M");
    qr.addData(value);
    qr.make();
    return qr.createSvgTag({ cellSize: 4, margin: 4, scalable: true });
  }, [value]);
  return (
    <div
      role="img"
      aria-label="Código QR de la URL NDEF"
      className="size-36 rounded-md border bg-white p-1 [&_svg]:size-full"
      dangerouslySetInnerHTML={{ __html: svg }}
    />
  );
}

/** Copia la URL NDEF y, opcionalmente, la muestra como QR (generado en el cliente) para pasarla al móvil. */
export function NdefUrlCopy({ url }: { url: string }) {
  const [showQr, setShowQr] = useState(false);
  return (
    <div className="grid gap-2">
      <div className="flex items-center gap-1">
        <code className="min-w-0 flex-1 truncate text-xs" title={url}>{url}</code>
        <CopyButton value={url} label="Copiar URL NDEF" />
        <Button
          type="button" variant="ghost" size="icon" aria-pressed={showQr}
          aria-label={showQr ? "Ocultar QR" : "Mostrar QR de la URL NDEF"}
          title="QR para pasar la URL al móvil" onClick={() => setShowQr((s) => !s)}
        >
          <QrCode />
        </Button>
      </div>
      {showQr ? <QrSvg value={url} /> : null}
    </div>
  );
}
