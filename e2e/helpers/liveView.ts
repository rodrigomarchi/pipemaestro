import { expect, type Page } from "@playwright/test";

/**
 * Waits until the LiveView socket is connected, so clicks reach the server
 * instead of landing on the dead render.
 */
export async function waitForLiveView(page: Page): Promise<void> {
  await expect(page.locator("[data-phx-main].phx-connected")).toBeVisible();
}

/**
 * Accepts the browser `confirm()` that `data-confirm` buttons raise. Playwright
 * dismisses dialogs by default, which would silently cancel the action.
 */
export function acceptConfirms(page: Page): void {
  if (pagesAcceptingConfirms.has(page)) return;
  pagesAcceptingConfirms.add(page);
  page.on("dialog", (dialog) => dialog.accept());
}

const pagesAcceptingConfirms = new WeakSet<Page>();
