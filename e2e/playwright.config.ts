import { defineConfig, devices } from "@playwright/test";

const e2ePort = process.env.E2E_PORT || "4003";
const baseURL = process.env.E2E_BASE_URL || `http://localhost:${e2ePort}`;

// The server runs at MIX_ENV=e2e on E2E_PORT against its own database
// (config/e2e.exs). Specs share one server and create their own data with
// unique names, so they run serially without a reset between them.
export default defineConfig({
  testDir: "./tests",
  globalSetup: "./global-setup.ts",
  fullyParallel: false,
  workers: 1,
  forbidOnly: !!process.env.CI,
  retries: 0,
  reporter: [["list"], ["html", { open: "never" }]],
  use: {
    baseURL,
    // The frontend tags what specs touch with data-testid; see README.md.
    testIdAttribute: "data-testid",
    trace: "retain-on-failure",
    screenshot: "only-on-failure",
    video: "retain-on-failure",
    actionTimeout: 10_000,
    navigationTimeout: 30_000,
  },
  projects: [
    {
      name: "chromium",
      testIgnore: /.*mobile.*\.spec\.ts/,
      use: {
        ...devices["Desktop Chrome"],
        viewport: { width: 1440, height: 900 },
        // SLOW_MO=300 (ms) with --headed to watch a spec unfold.
        launchOptions: { slowMo: Number(process.env.SLOW_MO) || 0 },
      },
    },
    {
      name: "mobile-chrome",
      testMatch: /.*mobile.*\.spec\.ts/,
      use: {
        ...devices["Pixel 7"],
        launchOptions: { slowMo: Number(process.env.SLOW_MO) || 0 },
      },
    },
  ],
  // Boots the e2e server from the repo root unless one is already up.
  webServer: {
    command: `cd .. && MIX_ENV=e2e E2E_PORT=${e2ePort} mix phx.server`,
    url: `${baseURL}/healthz`,
    reuseExistingServer: true,
    timeout: 180_000,
    stdout: "pipe",
    stderr: "pipe",
  },
});
