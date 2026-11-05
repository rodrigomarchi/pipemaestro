/**
 * Writes the landing's screenshots: `<name>.png` and `<name>-dark.png` in
 * apps/pipe_maestro_web/priv/static/images/landing/, always under the same
 * names, so a new run replaces the files in place.
 *
 * Each picture is the browser's viewport (the director's 1440x900 at scale 2),
 * so every file has the size `PipeMaestroWeb.LandingShots` declares. A file
 * over the size limit, or of another size, fails the run: the framing is fixed
 * here, not found out in review.
 */
import { expect, type Page } from "@playwright/test";
import { statSync } from "node:fs";
import { resolve } from "node:path";

export const LANDING_DIR = resolve(process.cwd(), "..", "apps", "pipe_maestro_web", "priv", "static", "images", "landing");

const MAX_BYTES = 600 * 1024;

// Toasts, cursors and the live-reload frame are not part of the screen, and the
// worktree's absolute path (a temporary directory of this machine) says nothing.
const HIDE = `
  [data-testid="toasts"], #toasts, iframe[hidden] { visibility: hidden !important; }
  div:has(> [data-testid="task-worktree"]) { display: none !important; }
  * { caret-color: transparent !important; }
`;

async function write(page: Page, name: string): Promise<void> {
  const path = resolve(LANDING_DIR, `${name}.png`);
  await page.screenshot({ path, animations: "disabled", style: HIDE, scale: "device" });

  const viewport = page.viewportSize()!;
  const { size } = statSync(path);
  expect(size, `${name}.png is over 600 KB; frame a smaller part of the screen`).toBeLessThan(MAX_BYTES);
  expect(viewport).toEqual({ width: 1440, height: 900 });
}

/**
 * Captures the viewport as `name`, light and dark. Scrolls `top` (a test id)
 * right below the app's header first, when given, so the picture frames it.
 */
export async function capture(page: Page, name: string, options: { top?: string } = {}): Promise<void> {
  if (options.top) {
    // Below the app's sticky header, with some air.
    await page.getByTestId(options.top).evaluate((el: HTMLElement) => {
      el.style.scrollMarginTop = "88px";
      el.scrollIntoView({ block: "start" });
    });
  } else {
    await page.evaluate(() => window.scrollTo(0, 0));
  }
  await page.mouse.move(0, 0);
  await page.waitForTimeout(400);
  await write(page, name);

  await page.emulateMedia({ colorScheme: "dark" });
  await page.evaluate(() => document.documentElement.classList.add("dark"));
  await page.waitForTimeout(300);
  await write(page, `${name}-dark`);
  await page.evaluate(() => document.documentElement.classList.remove("dark"));
  await page.emulateMedia({ colorScheme: "light" });
}

/**
 * Replaces text on the page before a capture: what only this machine shows (its
 * hostname, the local server's address) becomes the scenario's.
 */
export async function retext(page: Page, pairs: [string, string][]): Promise<void> {
  await page.evaluate((pairs) => {
    const walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT);
    for (let node = walker.nextNode(); node; node = walker.nextNode()) {
      let text = node.nodeValue ?? "";
      for (const [from, to] of pairs) text = text.split(from).join(to);
      if (text !== node.nodeValue) node.nodeValue = text;
    }
  }, pairs);
}
