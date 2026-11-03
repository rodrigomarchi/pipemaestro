/**
 * @section Workspace users
 * @flow A [done] A user in one workspace signs in straight to its board, sees their account and signs out
 * @flow B [done] A user in two workspaces picks one after signing in and switches from the top bar
 * @flow C [done] A password reset by an operator closes the user's open board and replaces the old password
 * @flow D [done] A disabled user cannot sign in until re-enabled
 */
import { expect, test } from "@playwright/test";
import { bootstrapOperator, uniqueSuffix, userPassword } from "../helpers/env";
import { shot } from "../helpers/screenshots";
import { AppPage } from "../pages/AppPage";
import { BackofficePage } from "../pages/BackofficePage";

test.describe("Workspace user sessions", () => {
  let backoffice: BackofficePage;

  test.beforeEach(async ({ page }) => {
    backoffice = new BackofficePage(page);
    await backoffice.signInExpectingSuccess(bootstrapOperator.email, bootstrapOperator.password);
  });

  test("one workspace goes straight to the board", async ({ browser }) => {
    const suffix = uniqueSuffix();
    const workspace = `Solo ${suffix}`;
    const user = { name: `Ana ${suffix}`, email: `ana-${suffix}@e2e.test` };

    await backoffice.createWorkspace(workspace);
    await backoffice.createMember(user.name, user.email, userPassword);

    const context = await browser.newContext();
    const app = new AppPage(await context.newPage());
    await app.signIn(user.email, userPassword);
    await app.expectBoard(workspace);
    await expect(app.page.getByTestId("board-column-running")).toBeVisible();
    await shot(app.page, "board");

    await app.openAccountMenu();
    await expect(app.page.getByTestId("account-name")).toHaveText(user.name);
    await expect(app.page.getByTestId("account-email")).toHaveText(user.email);
    await shot(app.page, "account-menu");

    await app.signOutFromAccountMenu();
    await app.signIn(user.email, userPassword);
    await app.expectBoard(workspace);
    await app.signOut();
    await app.page.goto("/workspaces");
    await app.expectSignInPage();
    await context.close();
  });

  test("several workspaces show the picker and the switcher", async ({ browser }) => {
    const suffix = uniqueSuffix();
    const first = { name: `Alfa ${suffix}`, slug: `alfa-${suffix}` };
    const second = { name: `Beta ${suffix}`, slug: `beta-${suffix}` };
    const user = { name: `Bruno ${suffix}`, email: `bruno-${suffix}@e2e.test` };

    await backoffice.createWorkspace(first.name);
    await backoffice.createMember(user.name, user.email, userPassword);
    await backoffice.createWorkspace(second.name);
    await backoffice.addExistingMember(user.email);

    const context = await browser.newContext();
    const app = new AppPage(await context.newPage());
    await app.signIn(user.email, userPassword);
    await expect(app.workspaceCard(first.slug)).toBeVisible();
    await expect(app.workspaceCard(second.slug)).toBeVisible();
    await shot(app.page, "workspace-picker");

    await app.pickWorkspace(first.slug, first.name);
    await app.switchWorkspace(second.slug, second.name);
    await shot(app.page, "switched-workspace");
    await context.close();
  });

  test("a password reset closes the open board", async ({ browser }) => {
    const suffix = uniqueSuffix();
    const workspace = `Reset ${suffix}`;
    const user = { name: `Caio ${suffix}`, email: `caio-${suffix}@e2e.test` };
    const newPassword = "outra-senha-e2e-longa";

    await backoffice.createWorkspace(workspace);
    await backoffice.createMember(user.name, user.email, userPassword);

    const context = await browser.newContext();
    const app = new AppPage(await context.newPage());
    await app.signIn(user.email, userPassword);
    await app.expectBoard(workspace);

    await backoffice.openUser(user.email);
    await backoffice.resetPassword(newPassword);
    await shot(backoffice.page, "password-reset");

    await app.expectSignInPage();
    await expect(app.toasts).toContainText("Sua sessão foi encerrada.");

    await app.signIn(user.email, userPassword);
    await app.expectRejected();
    await app.signIn(user.email, newPassword);
    await app.expectBoard(workspace);
    await context.close();
  });

  test("a disabled user cannot sign in until re-enabled", async ({ browser }) => {
    const suffix = uniqueSuffix();
    const workspace = `Bloqueio ${suffix}`;
    const user = { name: `Dora ${suffix}`, email: `dora-${suffix}@e2e.test` };

    await backoffice.createWorkspace(workspace);
    await backoffice.createMember(user.name, user.email, userPassword);
    await backoffice.openUser(user.email);
    await backoffice.disableUser();
    await shot(backoffice.page, "user-disabled");

    const context = await browser.newContext();
    const app = new AppPage(await context.newPage());
    await app.signIn(user.email, userPassword);
    await app.expectRejected();

    await backoffice.enableUser();
    await app.signIn(user.email, userPassword);
    await app.expectBoard(workspace);
    await context.close();
  });
});
