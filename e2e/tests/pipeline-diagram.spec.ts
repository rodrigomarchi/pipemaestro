/**
 * @section Tarefas e pipelines
 * @flow A [done] A member opens a pipeline's page from the list: the diagram shows each stage, the parallel group forking and joining, and the rail where a person decides; a stage opens its details in a side panel
 * @flow B [done] An admin edits on the diagram: a stage's panel holds its fields and the node follows the draft; a stage is inserted between two and runs at once with the one before
 * @flow C [done] The Formulário tab shows the same draft as cards, and saving lands on the pipeline's page with the new structure
 */
import { expect, test } from "@playwright/test";
import { bootstrapOperator, uniqueSuffix, userPassword } from "../helpers/env";
import { shot } from "../helpers/screenshots";
import { AppPage } from "../pages/AppPage";
import { BackofficePage } from "../pages/BackofficePage";
import { PipelinesPage } from "../pages/PipelinesPage";
import { clickPageAction } from "../helpers/pageActions";

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

    const viewport = memberApp.page.viewportSize();
    await memberApp.page.setViewportSize({ width: 390, height: 844 });
    await shot(memberApp.page, "pipeline-page-narrow");
    if (viewport) await memberApp.page.setViewportSize(viewport);

    // Flow B: the admin edits on the diagram.
    await pipelines.open(workspace.slug);
    await pipelines.openPage("Refatoração");
    await clickPageAction(adminApp.page, "pipeline-page-edit");
    await expect(pipelines.diagram).toBeVisible();
    await expect(adminApp.page.getByTestId("stage-card-0")).toHaveCount(0);

    await pipelines.selectStage(1);
    await expect(pipelines.stagePanel(1)).toBeVisible();
    await pipelines.stageName(1).fill("Refatoração em passos");
    await expect(pipelines.diagramStage(1)).toContainText("Refatoração em passos");
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

    // Flow C: the same draft as cards, then saved.
    await pipelines.openFormTab();
    await expect(pipelines.stageName(2)).toHaveValue("Testes de caracterização");
    await expect(adminApp.page.getByTestId("stage-group-2")).toHaveValue("paralelo-1");
    await adminApp.page.getByTestId("pipeline-save").click();

    await expect(pipelines.diagram).toBeVisible();
    await expect(adminApp.page.getByTestId("pipeline-page-version")).toHaveText("v2");
    await expect(pipelines.diagramStep(1)).toHaveAttribute("data-parallel");
    await expect(pipelines.diagramStage(3)).toContainText("Verificação");
  });
});
