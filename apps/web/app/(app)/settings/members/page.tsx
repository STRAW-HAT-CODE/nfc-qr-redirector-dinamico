import { Users } from "lucide-react";

import { EmptyState } from "@/components/empty-state";
import { ErrorState } from "@/components/error-state";
import { InviteDialog } from "@/components/members/invite-dialog";
import { MembersTable } from "@/components/members/members-table";
import { PageHeader } from "@/components/page-header";
import { ApiError, hasRole, listMembers, requireActiveOrg, type Member } from "@/lib/api";
import { createClient } from "@/lib/supabase/server";

export const metadata = { title: "Miembros · Dynamic QR" };

export default async function Page() {
  const { active } = await requireActiveOrg();
  if (!hasRole(active.role, "admin")) {
    return (
      <>
        <PageHeader title="Miembros" description={active.name} />
        <EmptyState icon={<Users />} title="Sin permiso" description="Solo los administradores pueden gestionar miembros." />
      </>
    );
  }

  let members: Member[] = [];
  let error: string | null = null;
  try {
    members = await listMembers(active.id);
  } catch (e) {
    if (!(e instanceof ApiError)) throw e;
    error = e.message;
  }

  const supabase = await createClient();
  const { data } = await supabase.auth.getClaims();
  const currentUserId = String(data?.claims?.sub ?? "");

  return (
    <>
      <PageHeader title="Miembros" description={active.name} actions={error ? null : <InviteDialog actor={active.role} />} />
      {error ? (
        <ErrorState message={error} />
      ) : members.length === 0 ? (
        <EmptyState icon={<Users />} title="Sin miembros" description="Añade a la primera persona con su user_id." action={<InviteDialog actor={active.role} />} />
      ) : (
        <MembersTable members={members} actor={active.role} currentUserId={currentUserId} />
      )}
    </>
  );
}
