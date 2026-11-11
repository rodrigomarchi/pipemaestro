/**
 * @section Public
 * @flow A [done] A visitor reads the landing page (the simple explanation and the
 *   diagrams) and reaches the sign-in from it
 * @flow D [done] A visitor sees the real product on the landing page: the board in the
 *   hero and a tour of the screens, in the theme of the page and without horizontal
 *   scroll on a phone
 * @flow E [done] A visitor goes from the landing to the documentation: an everyday example, the
 *   index beside the page, the next page, a screenshot in the page's theme, and on a phone
 *   the index folded in a menu, without horizontal scroll (its tables scroll on their own)
 * @flow F [done] A visitor follows the walkthrough from an empty workspace to the first task
 *   done: each step in order with its real screens, the pipeline with the menu closed and
 *   open side by side, the gate's close-up, in the page's theme and without horizontal scroll
 *   on a phone
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

/** The walkthrough's steps, by the screens each one shows. */
const WALKTHROUGH = [
  ["setup-runner"],
  ["setup-project"],
  ["setup-pipelines"],
  ["setup-gate"],
  ["setup-pipeline", "setup-pipeline-menu"],
  ["setup-pipeline-stage"],
  ["first-task-new"],
  ["first-task-running", "first-task-stage"],
  ["first-task-gate"],
  ["first-task-done"],
] as const;

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

/**
 * Loads every image of `container`, the lazy ones and those of the other theme included,
 * so a screenshot taken in either theme never catches an empty frame.
 */
async function loadAllShots(container: Locator) {
  await container.evaluate(async (root) => {
    const images = Array.from(root.querySelectorAll("img"));
    images.forEach((img) => {
      img.loading = "eager";
    });
    await Promise.all(
      images.map(async (img) => {
        if (!img.complete) {
          await new Promise((done) => {
            img.addEventListener("load", done, { once: true });
            img.addEventListener("error", done, { once: true });
          });
        }
        await img.decode().catch(() => undefined);
      }),
    );
  });
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
    await loadAllShots(page.locator("body"));
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
    await loadAllShots(tour);
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
    await loadAllShots(page.getByTestId("product-tour"));
    await shot(page.getByTestId("hero-screenshot"), "landing-hero-phone");
    await shot(page.getByTestId("product-tour"), "landing-tour-phone");
  });

  test("the landing page walks from an empty workspace to the first task", async ({ page }) => {
    await page.goto("/#passo-a-passo");
    const walkthrough = page.getByTestId("walkthrough");
    await expect(walkthrough).toBeInViewport();

    for (const [index, names] of WALKTHROUGH.entries()) {
      const step = page.getByTestId(`walkthrough-step-${index + 1}`);
      await step.scrollIntoViewIfNeeded();
      for (const name of names) await expectLoadedShot(step.getByTestId(`walkthrough-${name}`), name);
    }
    // The menu closed and open, side by side.
    const closed = await page.getByTestId("walkthrough-setup-pipeline").boundingBox();
    const open = await page.getByTestId("walkthrough-setup-pipeline-menu").boundingBox();
    expect(open!.x).toBeGreaterThan(closed!.x);
    expect(open!.y).toBe(closed!.y);

    await loadAllShots(walkthrough);
    await shot(page.getByTestId("walkthrough-step-1"), "landing-walkthrough-runner");
    await shot(page.getByTestId("walkthrough-step-5"), "landing-walkthrough-pipeline");
    await shot(page.getByTestId("walkthrough-step-9"), "landing-walkthrough-gate");

    await page.emulateMedia({ colorScheme: "dark" });
    await page.evaluate(() => document.documentElement.classList.add("dark"));
    const gate = page.getByTestId("walkthrough-step-9");
    await gate.scrollIntoViewIfNeeded();
    await expectLoadedShot(gate.getByTestId("walkthrough-first-task-gate"), "first-task-gate", "dark");
    await page.evaluate(() => document.documentElement.classList.remove("dark"));
    await page.emulateMedia({ colorScheme: "light" });

    await page.setViewportSize({ width: 390, height: 844 });
    await page.goto("/#passo-a-passo");
    await expect(walkthrough).toBeVisible();
    const overflow = await page.evaluate(
      () => document.documentElement.scrollWidth - document.documentElement.clientWidth,
    );
    expect(overflow).toBeLessThanOrEqual(0);
    await loadAllShots(walkthrough);
    await shot(page.getByTestId("walkthrough-step-1"), "landing-walkthrough-runner-phone");
    await shot(page.getByTestId("walkthrough-step-5"), "landing-walkthrough-pipeline-phone");
  });

  test("a visitor reads the documentation from the landing page", async ({ page }) => {
    await page.goto("/");
    await page.getByTestId("example-corrigir-um-bug").scrollIntoViewIfNeeded();
    await shot(page.getByTestId("landing-examples"), "landing-examples");
    await page.getByTestId("example-corrigir-um-bug").click();

    await expect(page.getByTestId("docs-title")).toHaveText("Corrigir um bug com teste de reprodução");
    await expect(page.getByTestId("docs-nav-corrigir-um-bug")).toHaveAttribute("aria-current", "page");
    const screen = page.getByTestId("docs-shot-task");
    await screen.scrollIntoViewIfNeeded();
    await expectLoadedShot(screen, "task");
    await page.evaluate(() => window.scrollTo(0, 0));
    await shot(page, "docs-example");

    await page.getByTestId("docs-next").click();
    await expect(page.getByTestId("docs-title")).toHaveText("Uma issue do GitHub vira PR sozinha");

    await page.getByTestId("docs-nav-primeiros-passos").click();
    await expect(page.getByTestId("docs-title")).toHaveText("Do zero ao primeiro PR");
    await expect(page.getByTestId("docs-previous")).toHaveCount(0);

    await page.getByTestId("docs-home").click();
    await expect(page.getByTestId("docs-section-exemplos")).toBeVisible();
    await shot(page, "docs-index");

    await page.setViewportSize({ width: 390, height: 844 });
    await page.goto("/docs/primeiros-passos");
    await expect(page.getByTestId("docs-nav-runner")).toBeHidden();
    await page.getByTestId("docs-menu").click();
    await page.getByTestId("docs-menu-runner").click();
    await expect(page.getByTestId("docs-title")).toHaveText("O runner na sua máquina");
    const overflow = () =>
      page.evaluate(() => document.documentElement.scrollWidth - document.documentElement.clientWidth);
    expect(await overflow()).toBeLessThanOrEqual(0);
    await shot(page, "docs-page-phone");

    // A page with wide tables scrolls them, not the page.
    await page.goto("/docs/comandos");
    expect(await overflow()).toBeLessThanOrEqual(0);
    await shot(page, "docs-tables-phone");
    await page.setViewportSize({ width: 1440, height: 900 });

    await page.goto("/");
    await page.getByTestId("nav-docs").click();
    await expect(page.getByTestId("docs-start")).toBeVisible();
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
