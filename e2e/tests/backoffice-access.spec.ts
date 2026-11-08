/**
 * @section Backoffice
 * @flow A [done] Wrong operator credentials are refused with a generic message
 * @flow B [done] An operator creates another operator, who signs in and out (account menu and sidebar); disabling them blocks the sign-in
 * @flow C [done] A workspace user's session never opens the backoffice, nor do their credentials
 */
import { expect, test } from "@playwright/test";
import { bootstrapOperator, uniqueSuffix, userPassword } from "../helpers/env";
import { shot } from "../helpers/screenshots";
import { AppPage } from "../pages/AppPage";
import { BackofficePage } from "../pages/BackofficePage";

test.describe("Backoffice access", () => {
  test("refuses wrong credentials", async ({ page }) => {
    const backoffice = new BackofficePage(page);
    await backoffice.signIn(bootstrapOperator.email, "senha errada demais");

    await backoffice.expectToast("E-mail ou senha inválidos.");
    await expect(page.getByTestId("operator-login-email")).toHaveValue(bootstrapOperator.email);
    await shot(page, "operator-login-rejected");
  });

  test("a new operator signs in until disabled", async ({ page, browser }) => {
    const backoffice = new BackofficePage(page);
    const suffix = uniqueSuffix();
    const operator = { name: `Op ${suffix}`, email: `op-${suffix}@e2e.test` };

    await backoffice.signInExpectingSuccess(bootstrapOperator.email, bootstrapOperator.password);
    await backoffice.createOperator(operator.name, operator.email, userPassword);
    await shot(page, "operators");

    const other = await browser.newContext();
    const otherBackoffice = new BackofficePage(await other.newPage());
    await otherBackoffice.signInExpectingSuccess(operator.email, userPassword);
    await otherBackoffice.signOut();
    await otherBackoffice.signInExpectingSuccess(operator.email, userPassword);
    await otherBackoffice.signOut();

    await backoffice.disableOperator(operator.email);
    await otherBackoffice.signIn(operator.email, userPassword);
    await otherBackoffice.expectToast("E-mail ou senha inválidos.");
    await other.close();
  });

  test("a workspace user cannot reach the backoffice", async ({ page, browser }) => {
    const backoffice = new BackofficePage(page);
    const suffix = uniqueSuffix();
    const workspace = `Isolada ${suffix}`;
    const user = { name: `Cliente ${suffix}`, email: `cliente-${suffix}@e2e.test` };

    await backoffice.signInExpectingSuccess(bootstrapOperator.email, bootstrapOperator.password);
    await backoffice.createWorkspace(workspace);
    await backoffice.createMember(user.name, user.email, userPassword);

    const customer = await browser.newContext();
    const app = new AppPage(await customer.newPage());
    await app.signIn(user.email, userPassword);
    await app.expectBoard(workspace);

    await app.page.goto("/backoffice/workspaces");
    await expect(app.page.getByTestId("operator-login-email")).toBeVisible();

    const asOperator = new BackofficePage(app.page);
    await asOperator.signIn(user.email, userPassword);
    await asOperator.expectToast("E-mail ou senha inválidos.");
    await customer.close();
  });
});
