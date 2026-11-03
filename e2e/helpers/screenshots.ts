/**
 * Opt-in visual evidence for the e2e suite.
 *
 * `shot()` does nothing unless `E2E_SHOTS` is set, so a spec carrying evidence
 * points behaves exactly like one that does not on a normal run. The evidence
 * lives inside the real spec, so the e2e run and the visual audit are one flow:
 *
 *     await backoffice.createWorkspace(name);
 *     await shot(page, "workspace-created");
 *
 *     make e2e.shots                         # every spec
 *     make e2e.shots FILE=tests/x.spec.ts    # one spec
 *
 * Files land in `e2e/screenshots/<spec>/<test>/<nn>-<name>[-dark].png`,
 * numbered in call order so the sequence reads as the story of the journey,
 * and are attached to the HTML report. With `E2E_SHOTS_DARK=1` every shot is
 * taken twice, light and dark, so both themes are audited in the same run.
 */
import { test, type Locator, type Page } from "@playwright/test";
import path from "node:path";

const SHOTS_DIR = "screenshots";
const counters = new Map<string, number>();

function enabled(flag: string | undefined): boolean {
  if (!flag) return false;
  const value = flag.trim().toLowerCase();
  return value !== "" && value !== "0" && value !== "false";
}

/** True when this run was asked for visual evidence. */
export function shotsEnabled(): boolean {
  return enabled(process.env.E2E_SHOTS);
}

function slugify(value: string): string {
  return (
    value
      .toLowerCase()
      .normalize("NFD")
      .replace(/[̀-ͯ]/g, "")
      .replace(/[^a-z0-9]+/g, "-")
      .replace(/^-+|-+$/g, "")
      .slice(0, 80) || "shot"
  );
}

function nextIndex(testId: string): string {
  const next = (counters.get(testId) ?? 0) + 1;
  counters.set(testId, next);
  return String(next).padStart(2, "0");
}

function pageOf(target: Page | Locator): Page {
  return "page" in target && typeof target.page === "function" ? target.page() : (target as Page);
}

async function capture(target: Page | Locator, filePath: string, name: string) {
  const fullPage = !("page" in target && typeof target.page === "function");
  await target.screenshot(fullPage ? { path: filePath, fullPage: true } : { path: filePath });
  await test.info().attach(name, { path: filePath, contentType: "image/png" });
}

/**
 * Captures `target` as evidence under `name`. No-op unless `E2E_SHOTS`.
 * Pass a `Page` for the whole page, or a `Locator` to frame one dialog or card.
 */
export async function shot(target: Page | Locator, name: string): Promise<void> {
  if (!shotsEnabled()) return;

  const info = test.info();
  const spec = path.basename(info.file).replace(/\.spec\.ts$/, "");
  const base = `${nextIndex(info.testId)}-${slugify(name)}`;
  const dir = path.resolve(process.cwd(), SHOTS_DIR, spec, slugify(info.title));
  const page = pageOf(target);

  // Let toasts and transitions settle so the picture shows a resting state.
  await page.waitForTimeout(250);
  await capture(target, path.join(dir, `${base}.png`), name);

  if (enabled(process.env.E2E_SHOTS_DARK)) {
    await page.emulateMedia({ colorScheme: "dark" });
    await page.evaluate(() => document.documentElement.classList.add("dark"));
    await page.waitForTimeout(150);
    await capture(target, path.join(dir, `${base}-dark.png`), `${name} (dark)`);
    await page.evaluate(() => document.documentElement.classList.remove("dark"));
    await page.emulateMedia({ colorScheme: "light" });
  }
}
