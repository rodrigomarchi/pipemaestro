/**
 * @section Phone
 * @flow A [done] On a phone every page of the workspace fits the screen's width and scrolls, the
 *   top bar's actions wrap under the title, and the menu, opened from the top bar, closes when one of
 *   its links is followed, leaving the next page scrollable
 */
import { expect, test, type Page } from "@playwright/test";
import { bootstrapOperator, uniqueSuffix, userPassword } from "../helpers/env";
import { waitForLiveView } from "../helpers/liveView";
import { shot } from "../helpers/screenshots";
import { AppPage } from "../pages/AppPage";
import { BackofficePage } from "../pages/BackofficePage";
import { PipelinesPage } from "../pages/PipelinesPage";

const pages = [
  "",
  "?aba=tarefas",
  "/decisions",
  "/proposals",
  "/jobs",
  "/tasks",
  "/pull-requests",
  "/runners",
  "/projects",
  "/pipelines",
  "/pipelines/new",
  "/usage",
  "/audit",
  "/secrets",
  "/integrations",
];

/** How the page sits in the phone's screen. */
async function layout(page: Page) {
  return page.evaluate(() => ({
    width: document.documentElement.scrollWidth,
    screen: window.innerWidth,
    locked: getComputedStyle(document.body).overflow === "hidden",
  }));
}

async function expectFitsAndScrolls(page: Page) {
  const { width, screen, locked } = await layout(page);
  expect(width, "the page is no wider than the screen").toBeLessThanOrEqual(screen);
  expect(locked, "the page scroll is not locked").toBe(false);
}

test.describe("Phone", () => {
  test("every page fits the screen and scrolls, through the menu too", async ({ browser }) => {
    const suffix = uniqueSuffix();
    const slug = `celular-${suffix}`;
    const user = { name: `Cel ${suffix}`, email: `cel-${suffix}@e2e.test` };

    // The operator's setup runs on a desktop: the backoffice is not the subject here.
    const desktop = await browser.newContext({
      viewport: { width: 1440, height: 900 },
      isMobile: false,
      hasTouch: false,
    });
    const backoffice = new BackofficePage(await desktop.newPage());
    await backoffice.signInExpectingSuccess(bootstrapOperator.email, bootstrapOperator.password);
    await backoffice.createWorkspace(`Celular ${suffix}`, slug);
    await backoffice.createMember(user.name, user.email, userPassword);
    await desktop.close();

    const phone = await browser.newContext();
    const app = new AppPage(await phone.newPage());
    await app.signIn(user.email, userPassword);
    await app.expectBoard(`Celular ${suffix}`);

    const pipelines = new PipelinesPage(app.page);
    await pipelines.open(slug);
    await pipelines.createDefaults();

    for (const path of pages) {
      await app.page.goto(`/w/${slug}${path}`);
      await waitForLiveView(app.page);
      await expectFitsAndScrolls(app.page);
    }

    await pipelines.open(slug);
    await expect(app.page.getByTestId("page-actions")).toBeVisible();
    await shot(app.page, "pipelines");

    await app.page.getByTestId("sidebar-open").click();
    await expect(app.page.getByTestId("app-sidebar")).toHaveAttribute("data-mobile-open", "true");
    await shot(app.page, "menu-open");
    await app.page.getByTestId("sidebar-usage").click();
    await expect(app.title).toHaveText("Uso e limites");
    await waitForLiveView(app.page);
    await expect(app.page.getByTestId("app-sidebar")).toHaveAttribute("data-mobile-open", "false");
    await expectFitsAndScrolls(app.page);

    await app.page.mouse.wheel(0, 600);
    await expect.poll(() => app.page.evaluate(() => window.scrollY)).toBeGreaterThan(0);
    await shot(app.page, "usage-scrolled");
    await phone.close();
  });
});
