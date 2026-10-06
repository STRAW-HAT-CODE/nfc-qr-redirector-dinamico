import { defineConfig, devices } from "@playwright/test";

import { loadE2eEnv, missingEnv } from "./e2e/env";

loadE2eEnv();

const API = "http://localhost:8000";
const WEB = "http://localhost:3000";

// Los webServer heredan el entorno del proceso; se fuerza lo local.
const localEnv = {
  PUBLIC_REDIRECT_BASE_URL: API,
  NEXT_PUBLIC_API_URL: API,
  TRUSTED_PROXY_HOPS: "0",
};
Object.assign(process.env, localEnv);

export default defineConfig({
  testDir: "./e2e",
  testMatch: /.*\.spec\.ts/,
  outputDir: "./test-results",
  reporter: [["list"], ["html", { open: "never", outputFolder: "playwright-report" }]],
  fullyParallel: false,
  workers: 1,
  retries: 0,
  timeout: 120_000,
  expect: { timeout: 15_000 },
  use: {
    baseURL: WEB,
    trace: "on",
    video: "on",
    screenshot: "only-on-failure",
    ...devices["Desktop Chrome"],
  },
  projects: [{ name: "chromium", use: { ...devices["Desktop Chrome"] } }],
  // Si faltan credenciales no se levantan servidores: el spec se salta y lo dice.
  webServer: missingEnv().length
    ? undefined
    : [
        {
          command: "uv run uvicorn app.main:app --port 8000",
          cwd: "../api",
          url: `${API}/healthz`,
          reuseExistingServer: !process.env.CI,
          timeout: 120_000,
          env: { ...(process.env as Record<string, string>) },
        },
        {
          command: "pnpm exec next dev -p 3000",
          url: `${WEB}/login`,
          reuseExistingServer: !process.env.CI,
          timeout: 180_000,
          env: { ...(process.env as Record<string, string>) },
        },
      ],
});
