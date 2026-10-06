import { ChevronDown } from "lucide-react";

interface Step {
  title: string;
  steps: React.ReactNode[];
}

const GUIDE: Step[] = [
  {
    title: "1. Qué chip comprar",
    steps: [
      "Compra chips NTAG213 (144 bytes): baratos y suficientes; la URL NDEF debe ocupar ≤ 137 bytes.",
      "NTAG215 (504 bytes) o NTAG216 (888 bytes) solo si necesitas margen.",
      "Evita MIFARE Classic: los iPhone no lo leen. Sobre metal usa etiquetas «anti-metal».",
    ],
  },
  {
    title: "2. Copia la URL NDEF",
    steps: [
      "Crea la etiqueta y copia su URL NDEF de la tabla (o pásala al móvil con el QR).",
      "Cada chip debe llevar su propia URL: el parámetro t identifica la ubicación.",
      "Si la etiqueta indica «No cabe en NTAG213», usa un chip mayor o un dominio más corto.",
    ],
  },
  {
    title: "3. Grabar en Android (NFC Tools)",
    steps: [
      "Instala NFC Tools desde Google Play y activa NFC en Ajustes.",
      "Escribir → Añadir un registro → URL / URI → pega la URL NDEF → OK.",
      "Pulsa «Escribir / 1 registro» y acerca el chip a la parte trasera, cerca de la cámara.",
    ],
  },
  {
    title: "4. Grabar en iPhone (NFC Tools)",
    steps: [
      "Instala NFC Tools desde la App Store (iPhone 7 o posterior, iOS 13+).",
      "Escribir → Añadir un registro → URL / URI → pega la URL NDEF → OK.",
      "Pulsa «Escribir / 1 registro» y acerca el chip a la parte superior del iPhone hasta ver la confirmación.",
      "Si falla, mantén el chip quieto 2-3 segundos y quita fundas gruesas.",
    ],
  },
  {
    title: "5. Probar",
    steps: [
      "Acerca el chip con el teléfono desbloqueado y comprueba que llegas al destino correcto.",
      "El escaneo aparece con canal nfc y la ubicación de la etiqueta (puede tardar unos segundos).",
      "Prueba con un iPhone y un Android antes de producir muchas unidades.",
    ],
  },
  {
    title: "6. Bloquear la escritura (opcional)",
    steps: [
      <strong key="w">⚠️ Es irreversible: un chip bloqueado no se puede volver a escribir.</strong>,
      "NFC Tools → Otros → Bloquear etiqueta. Hazlo solo cuando la URL esté verificada.",
      "El destino se cambia desde el panel sin reescribir el chip, así que bloquear es seguro.",
    ],
  },
];

/** Resumen de docs/nfc-guia.md. Acordeón accesible con <details> nativo. */
export function WriteGuide() {
  return (
    <div className="divide-y rounded-xl border">
      {GUIDE.map((g) => (
        <details key={g.title} className="group">
          <summary className="flex cursor-pointer list-none items-center justify-between gap-2 px-4 py-3 text-sm font-medium outline-none focus-visible:ring-2 focus-visible:ring-ring [&::-webkit-details-marker]:hidden">
            {g.title}
            <ChevronDown className="size-4 text-muted-foreground transition-transform group-open:rotate-180" aria-hidden="true" />
          </summary>
          <ol className="list-decimal space-y-1.5 px-4 pb-4 pl-9 text-sm text-muted-foreground">
            {g.steps.map((s, j) => (
              <li key={j}>{s}</li>
            ))}
          </ol>
        </details>
      ))}
    </div>
  );
}
