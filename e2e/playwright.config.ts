import { defineConfig, devices } from "@playwright/test";
import { versions } from "./helpers/env";

// The landing director (director/, `make landing.shots`) only exists in a run
// that asks for it: the suite never sees it, so it never rewrites the landing's
// images. It drives one long scripted scenario on a retina-sized desktop.
const director = process.env.E2E_DIRECTOR === "1";

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
      testDir: "./tests",
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
      testDir: "./tests",
      testMatch: /.*mobile.*\.spec\.ts/,
      use: {
        ...devices["Pixel 7"],
        launchOptions: { slowMo: Number(process.env.SLOW_MO) || 0 },
      },
    },
    ...(director
      ? [
          {
            name: "director",
            testDir: "./director",
            timeout: 600_000,
            use: {
              ...devices["Desktop Chrome"],
              viewport: { width: 1440, height: 900 },
              deviceScaleFactor: 2,
            },
          },
        ]
      : []),
  ],
  // Boots the e2e server from the repo root unless one is already up, built
  // as a fixed version so the runners' "outdated" badge is predictable.
  webServer: {
    command: `cd .. && CP_VERSION=${versions.controlPlane} MIX_ENV=e2e E2E_PORT=${e2ePort} mix phx.server`,
    url: `${baseURL}/healthz`,
    reuseExistingServer: true,
    timeout: 180_000,
    stdout: "pipe",
    stderr: "pipe",
  },
});
