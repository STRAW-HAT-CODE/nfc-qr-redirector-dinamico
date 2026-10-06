import { createClient, type SupabaseClient } from "@supabase/supabase-js";
import { expect, test } from "@playwright/test";
import jsQR from "jsqr";
import { readFileSync } from "node:fs";
import { PNG } from "pngjs";

import { loadE2eEnv, missingEnv, realEnv } from "./env";

loadE2eEnv();

const API = "http://localhost:8000";
const missing = missingEnv();

const stamp = Date.now();
const email = `e2e+${stamp}@example.com`;
const password = `Pw-${stamp}-e2e!`;
const orgName = `E2E Org ${stamp}`;
const orgSlug = `e2e-${stamp}`;
const DEST_A = "https://example.com/e2e-a";
const DEST_B = "https://example.com/e2e-b";

let admin: SupabaseClient | undefined;
let userId: string | undefined;

test.skip(missing.length > 0, `Faltan variables de entorno para el E2E: ${missing.join(", ")}`);

test.beforeAll(async () => {
  admin = createClient(realEnv("NEXT_PUBLIC_SUPABASE_URL")!, realEnv("SUPABASE_SERVICE_ROLE_KEY")!, {
    auth: { persistSession: false, autoRefreshToken: false },
  });
  const { data, error } = await admin.auth.admin.createUser({ email, password, email_confirm: true });
  if (error) throw new Error(`No se pudo crear el usuario de prueba: ${error.message}`);
  userId = data.user.id;
});

// Limpieza aunque el test falle: org (y lo que cuelga de ella) y usuario.
test.afterAll(async () => {
  if (!admin) return;
  const errors: string[] = [];
  const { data: orgs } = await admin.from("organizations").select("id").eq("slug", orgSlug);
  for (const o of orgs ?? []) {
    const { error } = await admin.from("organizations").delete().eq("id", o.id);
    if (error) errors.push(`org: ${error.message}`);
  }
  if (userId) {
    const { error } = await admin.auth.admin.deleteUser(userId);
    if (error) errors.push(`user: ${error.message}`);
  }
  if (errors.length) console.warn(`Limpieza incompleta (${errors.join("; ")})`);
});

test("crear enlace → descargar QR → escanear → métrica → cambiar destino", async ({ page, request }) => {
  // 1. Login
  await page.goto("/login");
  await page.getByLabel("Email").fill(email);
  await page.getByLabel("Contraseña").fill(password);
  await page.getByRole("button", { name: "Iniciar sesión" }).click();
  await page.waitForURL((u) => !u.pathname.startsWith("/login"));

  // 2. Crear organización
  await page.goto("/orgs");
  await page.getByRole("button", { name: "Crear organización" }).first().click();
  await page.getByLabel("Nombre").fill(orgName);
  await page.getByLabel("Identificador (slug)").fill(orgSlug);
  await page.getByRole("dialog").getByRole("button", { name: "Crear", exact: true }).click();
  await expect(page.getByRole("heading", { name: /Enlaces/ }).first()).toBeVisible();

  // 3. Crear enlace
  await page.goto("/links/new");
  await page.getByLabel("Nombre", { exact: true }).fill("Enlace E2E");
  await page.getByLabel("URL de destino").fill(DEST_A);
  await page.getByRole("button", { name: "Crear enlace" }).click();
  await page.waitForURL(/\/links\/[0-9a-f-]{36}$/);
  const linkId = page.url().split("/").pop()!;
  const shortUrl = (await page.locator("code").first().innerText()).trim();
  const slug = new URL(shortUrl).pathname.split("/").pop()!;
  expect(shortUrl).toMatch(/^http:\/\/localhost:8000\/r\//);

  // 4. Diseñador → descargar PNG → decodificar
  await page.getByRole("link", { name: "Diseñar QR" }).click();
  await page.waitForURL(/\/design$/);
  await page.getByRole("button", { name: /Descargar/ }).click();
  const [download] = await Promise.all([
    page.waitForEvent("download"),
    page.getByRole("menuitem", { name: /PNG 1024 px/ }).click(),
  ]);
  const file = await download.path();
  const png = PNG.sync.read(readFileSync(file));
  const decoded = jsQR(new Uint8ClampedArray(png.data), png.width, png.height);
  expect(decoded, "el QR descargado debe poder decodificarse").not.toBeNull();
  expect(decoded!.data).toBe(`${API}/r/${slug}?c=q`);

  // 5. «Escanear»: 302 sin seguir la redirección
  const scan = await request.get(decoded!.data, { maxRedirects: 0 });
  expect(scan.status()).toBe(302);
  expect(scan.headers()["location"]).toBe(DEST_A);

  // 6. Métricas: las de hoy salen en vivo de link_stats
  await expect(async () => {
    await page.goto(`/links/${linkId}/stats`);
    await expect(page.getByRole("group", { name: /^Escaneos: 1$/ })).toBeVisible({ timeout: 3_000 });
  }).toPass({ timeout: 60_000, intervals: [2_000, 5_000] });

  // 7. Cambiar destino con confirmación
  await page.goto(`/links/${linkId}`);
  await page.getByLabel("URL de destino").fill(DEST_B);
  await page.getByRole("button", { name: "Cambiar destino" }).click();
  await page.getByRole("alertdialog").getByRole("button", { name: "Sí, cambiar destino" }).click();
  await expect(page.getByText("Destino actualizado")).toBeVisible();

  // 8. Mismo slug → nuevo destino; el historial refleja el cambio
  await expect(async () => {
    const r = await request.get(`${API}/r/${slug}?c=q`, { maxRedirects: 0 });
    expect(r.status()).toBe(302);
    expect(r.headers()["location"]).toBe(DEST_B);
  }).toPass({ timeout: 30_000 });
  await page.reload();
  const history = page.locator("ol");
  await expect(history).toContainText(DEST_A);
  await expect(history).toContainText(DEST_B);
});
