import { ErrorState } from "@/components/error-state";
import { PageHeader } from "@/components/page-header";
import { BlocklistManager } from "@/components/platform/blocklist-manager";
import { ApiError, adminListBlockedDomains, type BlockedDomain } from "@/lib/api";

export const metadata = { title: "Consola Monky · Dominios bloqueados" };

export default async function Page() {
  let domains: BlockedDomain[] = [];
  let error: string | null = null;
  try {
    domains = await adminListBlockedDomains();
  } catch (e) {
    if (!(e instanceof ApiError)) throw e;
    error = e.message;
  }
  return (
    <>
      <PageHeader title="Dominios bloqueados" description="Destinos prohibidos en toda la plataforma (phishing, abuso)." />
      {error ? <ErrorState message={error} /> : <BlocklistManager domains={domains} />}
    </>
  );
}
