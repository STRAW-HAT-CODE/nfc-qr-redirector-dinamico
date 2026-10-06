import { Building2, ChevronsUpDown, Plus } from "lucide-react";
import Link from "next/link";

import { selectOrg } from "@/app/(app)/orgs/actions";
import {
  DropdownMenu,
  DropdownMenuContent,
  DropdownMenuItem,
  DropdownMenuLabel,
  DropdownMenuSeparator,
  DropdownMenuTrigger,
} from "@/components/ui/dropdown-menu";
import type { MyOrg } from "@/lib/api";

export function OrgSwitcher({ orgs, active }: { orgs: MyOrg[]; active: MyOrg | null }) {
  return (
    <DropdownMenu>
      <DropdownMenuTrigger
        className="flex w-full items-center gap-2 rounded-md border bg-card p-2 text-left text-sm hover:bg-accent focus-visible:outline-2 focus-visible:outline-ring"
        aria-label="Cambiar de organización"
      >
        <Building2 className="size-4 shrink-0 text-muted-foreground" aria-hidden="true" />
        <span className="min-w-0 flex-1 truncate font-medium">
          {active ? active.name : "Elegir organización"}
        </span>
        <ChevronsUpDown className="size-4 shrink-0 text-muted-foreground" aria-hidden="true" />
      </DropdownMenuTrigger>
      <DropdownMenuContent align="start" className="w-64">
        <DropdownMenuLabel className="text-xs text-muted-foreground">Mis organizaciones</DropdownMenuLabel>
        {orgs.length === 0 ? (
          <p className="px-2 py-1.5 text-sm text-muted-foreground">Aún no tienes organizaciones.</p>
        ) : (
          orgs.map((org) => (
            <form key={org.id} action={selectOrg}>
              <input type="hidden" name="orgId" value={org.id} />
              <DropdownMenuItem asChild>
                <button type="submit" className="w-full" aria-current={org.id === active?.id ? "true" : undefined}>
                  <span className="min-w-0 flex-1 truncate text-left">{org.name}</span>
                  <span className="text-xs text-muted-foreground">{org.role}</span>
                </button>
              </DropdownMenuItem>
            </form>
          ))
        )}
        <DropdownMenuSeparator />
        <DropdownMenuItem asChild>
          <Link href="/orgs">
            <Plus aria-hidden="true" /> Gestionar organizaciones
          </Link>
        </DropdownMenuItem>
      </DropdownMenuContent>
    </DropdownMenu>
  );
}
