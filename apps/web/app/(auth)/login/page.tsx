import { AuthForm } from "@/components/auth/auth-form";
import { ErrorState } from "@/components/error-state";
import { safeNext } from "@/lib/safe-next";

export const metadata = { title: "Iniciar sesión · Dynamic QR" };

export default async function LoginPage({
  searchParams,
}: {
  searchParams: Promise<{ next?: string; error?: string }>;
}) {
  const { next, error } = await searchParams;
  return (
    <div className="grid gap-4">
      <h1 className="text-xl font-semibold">Iniciar sesión</h1>
      {error ? (
        <ErrorState title="Enlace no válido" message="El enlace expiró o ya se usó. Solicita uno nuevo." />
      ) : null}
      <AuthForm mode="login" next={next ? safeNext(next) : undefined} />
    </div>
  );
}
