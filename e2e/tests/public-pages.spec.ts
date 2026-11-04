/**
 * @section Public
 * @flow A [done] A visitor reads the landing page (the simple explanation and the
 *   diagrams) and reaches the sign-in from it
 * @flow D [done] A visitor sees the real product on the landing page: the board in the
 *   hero and a tour of the screens, in the theme of the page and without horizontal
 *   scroll on a phone
 * @flow B [done] The sign-in page shows the e-mail and password form
 * @flow C [done] Every public page shows the PipeMaestro mark (its own SVG symbol and the
 *   name); the SVG favicon is checked by the control plane's ExUnit
 */
import { expect, type Locator, type Page, test } from "@playwright/test";
import { waitForLiveView } from "../helpers/liveView";
import { shot } from "../helpers/screenshots";

async function expectBrand(page: Page, testid = "brand") {
  const brand = page.getByTestId(testid);
  await expect(brand).toBeVisible();
  await expect(brand).toContainText("PipeMaestro");
  await expect(page.getByTestId(`${testid}-mark`)).toBeVisible();
}

const TOUR = ["board", "task", "decision", "audit", "usage", "runners"] as const;

/**
 * Checks that the screenshot of `name` shown inside `container` is the one for `theme`
 * and that the browser actually loaded it.
 */
async function expectLoadedShot(
  container: Locator,
  name: string,
  theme: "light" | "dark" = "light",
) {
  const file = theme === "dark" ? `${name}-dark` : name;
  const visible = container.locator("img:visible");
  await expect(visible).toHaveCount(1);
  await expect(visible).toHaveAttribute("src", new RegExp(`/images/landing/${file}[.-]`));
  await expect
    .poll(() => visible.evaluate((img: HTMLImageElement) => img.complete && img.naturalWidth))
    .toBeGreaterThan(0);
}

test.describe("Public pages", () => {
  test("the landing page leads to the sign-in", async ({ page }) => {
    await page.goto("/");
    await expect(page.getByTestId("hero-title")).toContainText("Da issue ao Pull Request");
    await expect(page.getByTestId("hero-journey")).toBeVisible();
    await expect(page.getByTestId("kid-step-6")).toBeVisible();
    for (const diagram of ["diagram-pipeline", "diagram-architecture", "diagram-stage"]) {
      await expect(page.getByTestId(diagram)).toBeVisible();
    }
    await shot(page, "landing");
    await shot(page.getByTestId("kid-explainer"), "landing-kid-explainer");
    await shot(page.getByTestId("diagram-architecture"), "landing-architecture");

    await page.setViewportSize({ width: 390, height: 844 });
    await shot(page, "landing-phone");
    await page.setViewportSize({ width: 1440, height: 900 });

    await page.getByTestId("nav-login").click();
    await expect(page.getByTestId("login-email")).toBeVisible();
  });

  test("the landing page shows the real product in the hero and in the tour", async ({ page }) => {
    await page.goto("/");

    const hero = page.getByTestId("hero-screenshot");
    await expect(hero).toBeVisible();
    await expectLoadedShot(hero, "board");

    await expect(page.getByTestId("nav-product")).toBeVisible();
    await page.getByTestId("nav-product").click();
    const tour = page.getByTestId("product-tour");
    await expect(tour).toBeInViewport();

    for (const name of TOUR) {
      const block = page.getByTestId(`tour-${name}`);
      await block.scrollIntoViewIfNeeded();
      await expect(block).toBeVisible();
      await expectLoadedShot(block, name);
    }
    await shot(hero, "landing-hero");
    await shot(tour, "landing-tour");

    await page.emulateMedia({ colorScheme: "dark" });
    await page.evaluate(() => document.documentElement.classList.add("dark"));
    for (const name of TOUR) {
      const block = page.getByTestId(`tour-${name}`);
      await block.scrollIntoViewIfNeeded();
      await expectLoadedShot(block, name, "dark");
    }
    await page.evaluate(() => document.documentElement.classList.remove("dark"));
    await page.emulateMedia({ colorScheme: "light" });

    await page.setViewportSize({ width: 390, height: 844 });
    await page.goto("/");
    await expect(page.getByTestId("hero-screenshot")).toBeVisible();
    const overflow = await page.evaluate(
      () => document.documentElement.scrollWidth - document.documentElement.clientWidth,
    );
    expect(overflow).toBeLessThanOrEqual(0);
    await shot(page.getByTestId("hero-screenshot"), "landing-hero-phone");
    await shot(page.getByTestId("product-tour"), "landing-tour-phone");
  });

  test("the sign-in page offers e-mail and password", async ({ page }) => {
    await page.goto("/login");
    await waitForLiveView(page);

    await expect(page.getByTestId("login-email")).toBeVisible();
    await expect(page.getByTestId("login-password")).toBeVisible();
    await shot(page, "login");
  });

  test("the public pages carry the PipeMaestro mark", async ({ page }) => {
    await page.goto("/");
    await expectBrand(page);
    await expectBrand(page, "footer-brand");
    await shot(page.getByTestId("brand"), "brand");

    await page.goto("/login");
    await waitForLiveView(page);
    await expectBrand(page);
    await shot(page.getByTestId("brand"), "login-brand");
  });
});
