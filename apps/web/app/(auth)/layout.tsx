import { QrCode } from "lucide-react";

export default function AuthLayout({ children }: { children: React.ReactNode }) {
  return (
    <main className="flex min-h-dvh flex-col items-center justify-center gap-6 px-4 py-10">
      <div className="flex items-center gap-2 text-lg font-semibold">
        <QrCode className="size-6 text-primary" aria-hidden="true" /> Dynamic QR
      </div>
      <div className="w-full max-w-sm rounded-xl border bg-card p-6 shadow-xs">{children}</div>
    </main>
  );
}
