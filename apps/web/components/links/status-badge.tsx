import { Badge } from "@/components/ui/badge";
import { cn } from "@/lib/utils";

import { STATUS_LABEL, type LinkStatus } from "./types";

const STYLE: Record<LinkStatus, string> = {
  active: "border-emerald-600/30 bg-emerald-600/10 text-emerald-800 dark:text-emerald-300",
  paused: "border-amber-600/30 bg-amber-600/10 text-amber-800 dark:text-amber-300",
  archived: "border-transparent bg-muted text-muted-foreground",
};

export function StatusBadge({ status }: { status: LinkStatus }) {
  return (
    <Badge variant="outline" className={cn(STYLE[status])}>
      {STATUS_LABEL[status]}
    </Badge>
  );
}
