/**
 * @section Backoffice
 * @flow A [done] An operator creates a workspace whose address is derived from its name, then renames it
 * @flow B [done] An operator creates a user straight into a workspace, adds an existing user and removes a member
 */
import { expect, test } from "@playwright/test";
import { bootstrapOperator, uniqueSuffix, userPassword } from "../helpers/env";
import { shot } from "../helpers/screenshots";
import { BackofficePage } from "../pages/BackofficePage";

test.describe("Backoffice workspaces", () => {
  let backoffice: BackofficePage;

  test.beforeEach(async ({ page }) => {
    backoffice = new BackofficePage(page);
    await backoffice.signInExpectingSuccess(bootstrapOperator.email, bootstrapOperator.password);
  });

  test("creates and renames a workspace", async ({ page }) => {
    const suffix = uniqueSuffix();

    await shot(page, "workspaces-list");
    await backoffice.createWorkspace(`Empresa ${suffix}`);
    await shot(page, "workspace-created");

    await backoffice.editWorkspace(`Renomeada ${suffix}`, `renomeada-${suffix}`);
    await expect(backoffice.workspace(`renomeada-${suffix}`)).toHaveText(`Renomeada ${suffix}`);
    await expect(page.getByTestId(`workspace-address-renomeada-${suffix}`)).toHaveText(
      `/w/renomeada-${suffix}`,
    );
    await shot(page, "workspace-renamed");
  });

  test("manages the members of a workspace", async ({ page }) => {
    const suffix = uniqueSuffix();
    const existing = { name: `Existente ${suffix}`, email: `existente-${suffix}@e2e.test` };
    const created = { name: `Nova ${suffix}`, email: `nova-${suffix}@e2e.test` };

    await backoffice.createUser(existing.name, existing.email, userPassword);
    await backoffice.createWorkspace(`Membros ${suffix}`);

    await backoffice.createMember(created.name, created.email, userPassword);
    await expect(backoffice.member(created.email)).toBeVisible();

    await backoffice.addExistingMember(existing.email);
    await expect(backoffice.member(existing.email)).toBeVisible();
    await expect(page.getByTestId("member-count")).toHaveText("2 membros");
    await shot(page, "workspace-with-members");

    await backoffice.removeMember(existing.email);
    await expect(backoffice.member(existing.email)).toHaveCount(0);
    await expect(page.getByTestId("member-count")).toHaveText("1 membro");
  });
});
