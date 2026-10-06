import { AuthForm } from "@/components/auth/auth-form";

export const metadata = { title: "Crear cuenta · Dynamic QR" };

export default function SignupPage() {
  return (
    <div className="grid gap-4">
      <h1 className="text-xl font-semibold">Crear cuenta</h1>
      <AuthForm mode="signup" />
    </div>
  );
}
