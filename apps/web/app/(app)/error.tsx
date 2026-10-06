"use client";

import { ErrorState } from "@/components/error-state";
import { Button } from "@/components/ui/button";

export default function Error({ reset }: { error: Error; reset: () => void }) {
  return (
    <ErrorState
      message="Ocurrió un error inesperado."
      action={<Button variant="outline" size="sm" onClick={reset}>Reintentar</Button>}
    />
  );
}
