import { LogOut, ShieldCheck } from "lucide-react";
import Link from "next/link";

import { logout } from "@/app/auth/actions";
import { ThemeToggleItems } from "@/components/layout/theme-toggle-items";
import {
  DropdownMenu,
  DropdownMenuContent,
  DropdownMenuItem,
  DropdownMenuLabel,
  DropdownMenuSeparator,
  DropdownMenuTrigger,
} from "@/components/ui/dropdown-menu";

export function UserMenu({ email, isPlatformAdmin = false }: { email: string; isPlatformAdmin?: boolean }) {
  const initial = (email[0] ?? "?").toUpperCase();
  return (
    <DropdownMenu>
      <DropdownMenuTrigger
        className="flex w-full items-center gap-2 rounded-md p-2 text-left text-sm hover:bg-accent focus-visible:outline-2 focus-visible:outline-ring"
        aria-label="Menú de usuario"
      >
        <span className="flex size-7 shrink-0 items-center justify-center rounded-full bg-primary text-xs font-semibold text-primary-foreground" aria-hidden="true">
          {initial}
        </span>
        <span className="min-w-0 truncate">{email}</span>
      </DropdownMenuTrigger>
      <DropdownMenuContent align="start" side="top">
        <DropdownMenuLabel className="truncate font-normal text-muted-foreground">{email}</DropdownMenuLabel>
        <DropdownMenuSeparator />
        {isPlatformAdmin ? (
          <>
            <DropdownMenuItem asChild>
              <Link href="/platform">
                <ShieldCheck aria-hidden="true" />
                Consola Monky
              </Link>
            </DropdownMenuItem>
            <DropdownMenuSeparator />
          </>
        ) : null}
        <ThemeToggleItems />
        <DropdownMenuSeparator />
        <form action={logout}>
          <DropdownMenuItem asChild>
            <button type="submit" className="w-full">
              <LogOut aria-hidden="true" />
              Cerrar sesión
            </button>
          </DropdownMenuItem>
        </form>
      </DropdownMenuContent>
    </DropdownMenu>
  );
}
