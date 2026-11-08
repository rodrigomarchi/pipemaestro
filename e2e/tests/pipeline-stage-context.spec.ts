/**
 * @section Tarefas e pipelines
 * @flow A [done] An admin sets a stage to continue the previous stage's agent session: the first stage is refused with the reason next to its context, a later stage is saved and the editor shows the choice again
 */
import { expect, test } from "@playwright/test";
import { bootstrapOperator, uniqueSuffix, userPassword } from "../helpers/env";
import { shot } from "../helpers/screenshots";
import { AppPage } from "../pages/AppPage";
import { BackofficePage } from "../pages/BackofficePage";
import { PipelinesPage } from "../pages/PipelinesPage";

test.describe("A stage's context", () => {
  test("a stage continues the previous stage's session", async ({ page, browser }) => {
    const suffix = uniqueSuffix();
    const workspace = { name: `Contexto ${suffix}`, slug: `contexto-${suffix}` };
    const admin = { name: `Ada ${suffix}`, email: `ada-${suffix}@e2e.test` };

    const backoffice = new BackofficePage(page);
    await backoffice.signInExpectingSuccess(bootstrapOperator.email, bootstrapOperator.password);
    await backoffice.createWorkspace(workspace.name);
    await backoffice.createMember(admin.name, admin.email, userPassword);

    const app = new AppPage(await (await browser.newContext()).newPage());
    await app.signIn(admin.email, userPassword);
    await app.expectBoard(workspace.name);
    const pipelines = new PipelinesPage(app.page);
    await pipelines.open(workspace.slug);
    await pipelines.createDefaults();

    await pipelines.edit("Refatoração");
    await pipelines.openStage(0);
    await pipelines.openAdvanced(0);
    await expect(pipelines.stageContext(0)).toHaveValue("fresh");
    await pipelines.stageContext(0).selectOption("continue");
    await app.page.getByTestId("stage-panel-0-save").click();

    // The drawer stays open, with the reason next to the context.
    await expect(pipelines.stagePanel(0)).toContainText(
      "a primeira etapa não tem uma etapa anterior para continuar",
    );
    await expect(pipelines.stageContext(0)).toBeVisible();
    await shot(app.page, "stage-context-error");

    await pipelines.stageContext(0).selectOption("fresh");
    await pipelines.closePanel(0);
    await pipelines.openStage(1);
    await pipelines.openAdvanced(1);
    await pipelines.stageContext(1).selectOption("continue");
    await shot(app.page, "stage-context-continue");
    await pipelines.save();

    await pipelines.edit("Refatoração");
    await expect(pipelines.stageContext(0)).toHaveValue("fresh");
    await expect(pipelines.stageContext(1)).toHaveValue("continue");
  });
});
