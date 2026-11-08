/**
 * @section Tarefas e pipelines
 * @flow A [done] A member opens a pipeline's page from the list: the diagram, top to bottom, shows each stage, the parallel group side by side and where a person decides; a stage opens its details in the drawer
 * @flow B [done] An admin edits on the same diagram: a stage's drawer holds its fields and the node follows the draft; a stage is inserted between two and runs at once with the one before, and one is added after the last
 * @flow C [done] Saving from a drawer lands on the pipeline's page with the new structure
 */
import { expect, test } from "@playwright/test";
import { bootstrapOperator, uniqueSuffix, userPassword } from "../helpers/env";
import { shot } from "../helpers/screenshots";
import { AppPage } from "../pages/AppPage";
import { BackofficePage } from "../pages/BackofficePage";
import { PipelinesPage } from "../pages/PipelinesPage";
import { clickPageAction } from "../helpers/pageActions";
import { waitForLiveView } from "../helpers/liveView";

test.describe("Pipeline diagram", () => {
  test("shows and edits a pipeline as a diagram", async ({ page, browser }) => {
    const suffix = uniqueSuffix();
    const workspace = { name: `Diagrama ${suffix}`, slug: `diagrama-${suffix}` };
    const admin = { name: `Ada ${suffix}`, email: `ada-${suffix}@e2e.test` };
    const member = { name: `Beto ${suffix}`, email: `beto-${suffix}@e2e.test` };

    const backoffice = new BackofficePage(page);
    await backoffice.signInExpectingSuccess(bootstrapOperator.email, bootstrapOperator.password);
    await backoffice.createWorkspace(workspace.name);
    // The first member is the workspace's admin.
    await backoffice.createMember(admin.name, admin.email, userPassword);
    await backoffice.createMember(member.name, member.email, userPassword);

    const adminApp = new AppPage(await (await browser.newContext()).newPage());
    await adminApp.signIn(admin.email, userPassword);
    await adminApp.expectBoard(workspace.name);
    const pipelines = new PipelinesPage(adminApp.page);
    await pipelines.open(workspace.slug);
    await pipelines.createDefaults();
    await shot(adminApp.page, "pipelines-list");

    // Flow A: a member reads the pipeline as a diagram.
    const memberApp = new AppPage(await (await browser.newContext()).newPage());
    await memberApp.signIn(member.email, userPassword);
    await memberApp.expectBoard(workspace.name);
    const reader = new PipelinesPage(memberApp.page);
    await reader.open(workspace.slug);
    await reader.openPage("Nova funcionalidade");

    await expect(reader.diagramStage(0)).toContainText("Especificação");
    await expect(reader.diagramStep(3)).toHaveAttribute("data-parallel");
    await expect(reader.diagramStep(3)).toContainText("Revisão de segurança");
    await expect(memberApp.page.getByTestId("diagram-rail")).toContainText("Pessoa decide");
    await expect(memberApp.page.getByTestId("pipeline-page-edit")).toHaveCount(0);
    await shot(memberApp.page, "pipeline-page");

    await reader.selectStage(2);
    await expect(reader.pagePanel).toContainText("Implementação");
    await expect(memberApp.page.getByTestId("stage-details-prompt")).toContainText("Implemente o plano");
    await shot(memberApp.page, "pipeline-page-stage");
    // A stage with only a prompt has nothing a tab away.
    await expect(memberApp.page.getByTestId("stage-details-tabs")).toHaveCount(0);

    const viewport = memberApp.page.viewportSize();
    await memberApp.page.setViewportSize({ width: 390, height: 844 });
    await shot(memberApp.page, "pipeline-page-narrow");
    if (viewport) await memberApp.page.setViewportSize(viewport);

    // Flow B: the admin edits on the diagram.
    await pipelines.open(workspace.slug);
    await pipelines.openPage("Refatoração");
    await clickPageAction(adminApp.page, "pipeline-page-edit");
    await pipelines.expectEditor();
    await waitForLiveView(adminApp.page);

    await pipelines.selectStage(1);
    await expect(pipelines.stagePanel(1)).toBeVisible();
    await pipelines.stageName(1).fill("Refatoração em passos");
    await expect(pipelines.diagramStage(1)).toContainText("Refatoração em passos");
    // The rest of the stage is a tab away from its prompt and model.
    await pipelines.openStageTab(1, "verificacao");
    await shot(adminApp.page, "pipeline-editor-panel-verification");
    await pipelines.closePanel(1);

    await pipelines.insertStageAt(2);
    await pipelines.stageName(2).fill("Testes de caracterização");
    await pipelines.stagePrompt(2).fill("Escreva testes que fixem o comportamento atual.");
    await shot(adminApp.page, "pipeline-editor-panel");
    await pipelines.closePanel(2);

    await pipelines.joinGroup(2);
    await expect(pipelines.diagramStep(1)).toHaveAttribute("data-parallel");
    await expect(pipelines.diagramStep(1)).toContainText("Testes de caracterização");
    await shot(adminApp.page, "pipeline-editor-diagram");

    await pipelines.insertStageAt(4);
    await pipelines.stageName(4).fill("Revisão final");
    await pipelines.stagePrompt(4).fill("Revise o diff inteiro.");
    await pipelines.closePanel(4);
    await expect(pipelines.diagramStage(4)).toContainText("Revisão final");

    const narrow = adminApp.page.viewportSize();
    await adminApp.page.setViewportSize({ width: 390, height: 844 });
    await shot(adminApp.page, "pipeline-editor-narrow");
    await pipelines.openStage(2);
    await shot(adminApp.page, "pipeline-editor-panel-narrow");
    if (narrow) await adminApp.page.setViewportSize(narrow);

    // Flow C: saved from the drawer.
    await expect(adminApp.page.getByTestId("stage-group-2")).toHaveValue("paralelo-1");
    await adminApp.page.getByTestId("stage-panel-2-save").click();

    await expect(pipelines.diagram).toBeVisible();
    await expect(adminApp.page.getByTestId("pipeline-page-version")).toHaveText("v2");
    await expect(pipelines.diagramStep(1)).toHaveAttribute("data-parallel");
    await expect(pipelines.diagramStage(3)).toContainText("Verificação");
    await expect(pipelines.diagramStage(4)).toContainText("Revisão final");
  });
});
