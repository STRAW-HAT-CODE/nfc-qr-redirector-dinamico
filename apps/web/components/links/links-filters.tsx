"use client";

import { Search } from "lucide-react";
import { usePathname, useRouter } from "next/navigation";
import { useState } from "react";

import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from "@/components/ui/select";

const ALL = "all";

export function LinksFilters({ q, status }: { q: string; status: string }) {
  const router = useRouter();
  const pathname = usePathname();
  const [text, setText] = useState(q);
  const [st, setSt] = useState(status || ALL);

  function apply(nextText: string, nextStatus: string) {
    const sp = new URLSearchParams();
    if (nextText.trim()) sp.set("q", nextText.trim());
    if (nextStatus !== ALL) sp.set("status", nextStatus);
    const qs = sp.toString();
    router.push(qs ? `${pathname}?${qs}` : pathname);
  }

  return (
    <form
      role="search"
      className="mb-4 flex flex-col gap-2 sm:flex-row"
      onSubmit={(e) => {
        e.preventDefault();
        apply(text, st);
      }}
    >
      <div className="relative flex-1">
        <Search className="pointer-events-none absolute top-1/2 left-3 size-4 -translate-y-1/2 text-muted-foreground" aria-hidden="true" />
        <Input
          type="search"
          value={text}
          onChange={(e) => setText(e.target.value)}
          placeholder="Buscar por nombre…"
          aria-label="Buscar enlaces"
          maxLength={120}
          className="pl-9"
        />
      </div>
      <Select
        value={st}
        onValueChange={(v) => {
          setSt(v);
          apply(text, v);
        }}
      >
        <SelectTrigger aria-label="Filtrar por estado" className="w-full sm:w-44">
          <SelectValue />
        </SelectTrigger>
        <SelectContent>
          <SelectItem value={ALL}>Todos los estados</SelectItem>
          <SelectItem value="active">Activos</SelectItem>
          <SelectItem value="paused">Pausados</SelectItem>
          <SelectItem value="archived">Archivados</SelectItem>
        </SelectContent>
      </Select>
      <Button type="submit" variant="secondary">
        Buscar
      </Button>
    </form>
  );
}
