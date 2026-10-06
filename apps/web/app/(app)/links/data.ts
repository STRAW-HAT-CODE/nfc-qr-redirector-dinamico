import "server-only";

import { api } from "@/lib/api";
import type { HistoryItem, LinkItem, LinkStatus, Page } from "@/components/links/types";

export const PAGE_SIZE = 20;

export function listLinks(params: { q?: string; status?: LinkStatus; offset: number }) {
  const sp = new URLSearchParams({ limit: String(PAGE_SIZE), offset: String(params.offset) });
  if (params.q) sp.set("q", params.q);
  if (params.status) sp.set("status", params.status);
  return api<Page<LinkItem>>(`/v1/links?${sp}`);
}

export const getLink = (id: string) => api<LinkItem>(`/v1/links/${encodeURIComponent(id)}`);

export const getHistory = (id: string) =>
  api<Page<HistoryItem>>(`/v1/links/${encodeURIComponent(id)}/history?limit=20`);
