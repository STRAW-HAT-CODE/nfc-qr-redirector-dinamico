/** Solo rutas internas (evita open redirects). */
export function safeNext(value: string | null | undefined, fallback = "/orgs") {
  if (!value || !value.startsWith("/") || value.startsWith("//") || value.includes("\\")) {
    return fallback;
  }
  return value;
}
