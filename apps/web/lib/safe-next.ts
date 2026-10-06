/** Solo rutas internas (evita open redirects). */
export function safeNext(value: string | null | undefined, fallback = "/orgs") {
  if (!value || !value.startsWith("/") || value.startsWith("//") || value.includes("\\")) {
    return fallback;
  }
  // El parser WHATWG elimina TAB/LF/CR: '/\t/evil.com' pasaría a '//evil.com'.
  if (/[\u0000-\u001f\u007f]/.test(value)) return fallback;
  try {
    const url = new URL(value, "http://x");
    if (url.origin !== "http://x") return fallback;
    return url.pathname + url.search + url.hash;
  } catch {
    return fallback;
  }
}
