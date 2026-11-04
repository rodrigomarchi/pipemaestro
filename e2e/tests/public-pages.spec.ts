/**
 * @section Public
 * @flow A [done] A visitor reads the landing page (the simple explanation and the
 *   diagrams) and reaches the sign-in from it
 * @flow B [done] The sign-in page shows the e-mail and password form
 */
import { expect, test } from "@playwright/test";
import { waitForLiveView } from "../helpers/liveView";
import { shot } from "../helpers/screenshots";

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

  test("the sign-in page offers e-mail and password", async ({ page }) => {
    await page.goto("/login");
    await waitForLiveView(page);

    await expect(page.getByTestId("login-email")).toBeVisible();
    await expect(page.getByTestId("login-password")).toBeVisible();
    await shot(page, "login");
  });
});
