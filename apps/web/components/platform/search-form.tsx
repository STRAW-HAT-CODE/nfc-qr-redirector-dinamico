"use client";

import { Search } from "lucide-react";
import { usePathname, useRouter } from "next/navigation";
import { useState } from "react";

import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";

export function SearchForm({ q, placeholder, label }: { q: string; placeholder: string; label: string }) {
  const router = useRouter();
  const pathname = usePathname();
  const [text, setText] = useState(q);
  return (
    <form
      role="search"
      className="mb-4 flex gap-2"
      onSubmit={(e) => {
        e.preventDefault();
        const t = text.trim();
        router.push(t ? `${pathname}?q=${encodeURIComponent(t)}` : pathname);
      }}
    >
      <div className="relative flex-1">
        <Search className="pointer-events-none absolute top-1/2 left-3 size-4 -translate-y-1/2 text-muted-foreground" aria-hidden="true" />
        <Input type="search" value={text} onChange={(e) => setText(e.target.value)} placeholder={placeholder} aria-label={label} maxLength={120} className="pl-9" />
      </div>
      <Button type="submit" variant="secondary">Buscar</Button>
    </form>
  );
}
