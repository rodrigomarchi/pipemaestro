/**
 * @section Tarefas e pipelines
 * @flow A An admin turns off the automatic analysis of failures in the pipeline's "Entrega" tab: the switch starts on, is saved off, the pipeline's summary says so and the editor shows it off again
 */
import { expect, test } from "@playwright/test";
import { bootstrapOperator, uniqueSuffix, userPassword } from "../helpers/env";
import { shot } from "../helpers/screenshots";
import { AppPage } from "../pages/AppPage";
import { BackofficePage } from "../pages/BackofficePage";
import { PipelinesPage } from "../pages/PipelinesPage";

test.describe("The automatic analysis of failures", () => {
  test("an admin turns it off for a pipeline", async ({ page, browser }) => {
    const suffix = uniqueSuffix();
    const workspace = { name: `Análise ${suffix}`, slug: `analise-${suffix}` };
    const admin = { name: `Lia ${suffix}`, email: `lia-${suffix}@e2e.test` };

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

    await pipelines.edit("Correção de bug");
    await pipelines.openEntry();
    await pipelines.openEntryTab("entrega");
    await expect(pipelines.autoAnalysis).toBeChecked();
    // Petal's switch hides its input (sr-only): the keyboard toggles it.
    await pipelines.autoAnalysis.focus();
    await app.page.keyboard.press("Space");
    await expect(pipelines.autoAnalysis).not.toBeChecked();
    await shot(app.page.getByTestId("pipeline-panel-panel-entrega"), "pipeline-auto-analysis");
    await pipelines.save();

    await pipelines.openPage("Correção de bug");
    await pipelines.openEntry();
    await expect(app.page.getByTestId("pipeline-summary-no-analysis")).toBeVisible();

    await pipelines.open(workspace.slug);
    await pipelines.edit("Correção de bug");
    await pipelines.openEntry();
    await pipelines.openEntryTab("entrega");
    await expect(pipelines.autoAnalysis).not.toBeChecked();
  });
});
