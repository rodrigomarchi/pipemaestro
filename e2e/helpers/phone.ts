import { expect, type Page } from "@playwright/test";
import { shot } from "./screenshots";

/**
 * Narrows the page to a phone's width, checks that nothing pushes it wider
 * than the screen (a wider page zooms out and scrolls sideways on a phone),
 * records it as `<name>-phone` and restores the viewport.
 */
export async function expectFitsPhone(page: Page, name: string) {
  const viewport = page.viewportSize();
  await page.setViewportSize({ width: 390, height: 844 });
  await expect
    .poll(() => page.evaluate(() => document.documentElement.scrollWidth - window.innerWidth))
    .toBeLessThanOrEqual(0);
  await shot(page, `${name}-phone`);
  if (viewport) await page.setViewportSize(viewport);
}
