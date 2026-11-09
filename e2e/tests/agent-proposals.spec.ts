/**
 * @section Tarefas e pipelines
 * @flow A [done] A member asks the agent to write a task from an idea, without auto-approval; the proposal opens the new-task form filled with it, and the task runs
 * @flow D [done] A member asks the agent to write a task for a chosen pipeline, auto-approval on (the default); the task is created and started without review
 * @flow E [done] A task the agent finds not ready is left for review, saying why it was not created on its own
 * @flow F [done] Answering the questionnaire of a task not ready asks a new round with the answers, which becomes the task
 * @flow B [done] A task stops for a decision; the agent suggests one, and applying it (retry with its instructions) lets the task finish
 * @flow C [done] An admin asks the agent to improve a pipeline from how its tasks went; the notes are saved and the revised pipeline becomes its next version
 */
import { expect, test } from "@playwright/test";
import { bootstrapOperator, uniqueSuffix, userPassword } from "../helpers/env";
import { waitForLiveView } from "../helpers/liveView";
import { RunnerProcess } from "../helpers/runnerProcess";
import { shot } from "../helpers/screenshots";
import { expectFitsPhone } from "../helpers/phone";
import { AppPage } from "../pages/AppPage";
import { BackofficePage } from "../pages/BackofficePage";
import { PipelinesPage } from "../pages/PipelinesPage";
import { ProjectsPage } from "../pages/ProjectsPage";
import { ProposalPage } from "../pages/ProposalPage";
import { RunnersPage } from "../pages/RunnersPage";
import { TasksPage } from "../pages/TasksPage";
import { clickPageAction } from "../helpers/pageActions";

test.describe("Agent proposals", () => {
  // Real CLI processes: the first one may compile the runner app.
  test.setTimeout(300_000);

  let runner: RunnerProcess;

  test.afterEach(() => runner?.cleanup());

  test("the agent writes a task, suggests a decision and improves a pipeline", async ({ page, browser }) => {
    const suffix = uniqueSuffix();
    const workspace = { name: `Assistente ${suffix}`, slug: `assistente-${suffix}` };
    const user = { name: `Alice ${suffix}`, email: `alice-${suffix}@e2e.test` };
    const runnerName = `agente-${suffix}`;

    const backoffice = new BackofficePage(page);
    await backoffice.signInExpectingSuccess(bootstrapOperator.email, bootstrapOperator.password);
    await backoffice.createWorkspace(workspace.name);
    await backoffice.createMember(user.name, user.email, userPassword);

    const context = await browser.newContext();
    const app = new AppPage(await context.newPage());
    await app.signIn(user.email, userPassword);
    await app.expectBoard(workspace.name);

    runner = new RunnerProcess();
    const root = runner.createCodeRoot();
    runner.start("runner.login", ["--url", app.page.url().replace(/\/w\/.*$/, "")]);
    const [, code] = await runner.waitFor(/digite o código:\s+([A-Z]{4}-[A-Z]{4})/);
    await new RunnersPage(app.page).approve(code, runnerName);
    expect(await runner.waitForExit()).toBe(0);
    runner.start("runner.start", ["--root", root]);
    await runner.waitFor(/Online como/);

    const pipelines = new PipelinesPage(app.page);
    await pipelines.open(workspace.slug);
    await pipelines.createDefaults();
    const projects = new ProjectsPage(app.page);
    await projects.open(workspace.slug);
    await projects.create({ name: "App", runner: runnerName, directory: "app" });

    const proposal = new ProposalPage(app.page);
    const tasks = new TasksPage(app.page);

    // Flow A: a task written from an idea.
    await tasks.open(workspace.slug);
    await clickPageAction(app.page, "task-generate");
    await app.page.getByTestId("proposal-request-text").fill("O login trava quando muita gente entra junto.");
    await expect(app.page.getByTestId("proposal-request-auto-approve")).toBeChecked();
    await shot(app.page, "task-proposal-request");
    await proposal.submitRequest({ project: "App", autoApprove: false });
    await proposal.waitForAnswer();
    await expect(app.page.getByTestId("proposal-task-title")).toHaveText("Destravar o login sob carga");
    await expect(app.page.getByTestId("proposal-task-prompt")).toContainText("Critérios de aceite");
    await expect(app.page.getByTestId("proposal-task-pipeline")).toContainText("Prompt único");
    await shot(app.page, "task-proposal-review");

    await proposal.createTask();
    await expect(app.page.getByTestId("task-title")).toHaveValue("Destravar o login sob carga");
    await shot(app.page, "task-proposal-form");
    await app.page.getByTestId("task-submit").click();
    await expect(tasks.status).toHaveText("Concluída", { timeout: 60_000 });

    // Flow D: a task written for a chosen pipeline, created and started without review.
    await tasks.open(workspace.slug);
    await clickPageAction(app.page, "task-generate");
    await app.page.getByTestId("proposal-request-text").fill("O login trava de novo.");
    await proposal.submitRequest({ project: "App", pipeline: "Correção de bug" });
    // The agent names "Prompt único", but the chosen pipeline holds. Watching the proposal, the
    // person is taken to the task; had it been created before the page connected, the link leads there.
    const taskUrl = /\/tasks\/[0-9a-f-]+$/;
    await Promise.race([
      app.page.waitForURL(taskUrl, { timeout: 60_000 }),
      proposal.createdTaskLink.waitFor({ timeout: 60_000 }),
    ]);
    if (!taskUrl.test(app.page.url())) await proposal.createdTaskLink.click();
    await app.page.waitForURL(taskUrl);
    await waitForLiveView(app.page);
    await expect(app.page.getByTestId("task-node-entrada")).toContainText("Correção de bug");
    // The request is the pipeline's entry, opened in a drawer (one more step back).
    await app.page.getByTestId("task-node-entrada").click();
    await expect(app.page.getByTestId("task-prompt-text")).toContainText("Critérios de aceite");
    await app.page.goBack();
    await expect(app.page.getByTestId("task-node-panel")).toHaveCount(0);
    await app.page.goBack();
    await waitForLiveView(app.page);
    await expect(proposal.createdTaskLink).toBeVisible();
    await expect(app.page.getByTestId("proposal-create-task")).toHaveCount(0);
    await shot(app.page, "task-proposal-auto-created");

    // Flow E: a task the agent finds not ready stays for review.
    await tasks.open(workspace.slug);
    await clickPageAction(app.page, "task-generate");
    await app.page.getByTestId("proposal-request-text").fill("Melhorar o login [nao-pronta]");
    await proposal.submitRequest({ project: "App" });
    await proposal.waitForAnswer();
    await expect(proposal.autoApproveSkipped).toContainText("Qual o limite de logins simultâneos?");
    await expect(proposal.autoApproveSkipped).toContainText("100 simultâneos (recomendada)");
    await expect(app.page.getByTestId("proposal-create-task")).toBeVisible();
    await shot(app.page, "task-proposal-auto-skipped");

    // Flow F: the questions are answered on the proposal; the new round becomes the task.
    await expect(proposal.questionnaire).toBeVisible();
    await expect(proposal.questionOption(0, 0)).toContainText("100 simultâneos");
    await expect(proposal.questionOption(0, 0)).toContainText("recomendada");
    await expect(proposal.questionnairePart("advance")).toHaveCount(0);
    await expect(proposal.questionnairePart("progress")).toContainText("0 de 1");
    await shot(app.page, "task-proposal-questions");
    const questioned = app.page.url();
    await proposal.questionOption(0, 0).click();
    await expect(proposal.questionnairePart("progress")).toContainText("1 de 1");
    await proposal.sendAnswers();
    await app.page.waitForURL((url) => url.href !== questioned);
    // Watching the new round, the person is taken to the task it becomes (auto-approval holds).
    await Promise.race([
      app.page.waitForURL(taskUrl, { timeout: 60_000 }),
      proposal.createdTaskLink.waitFor({ timeout: 60_000 }),
    ]);
    if (!taskUrl.test(app.page.url())) await proposal.createdTaskLink.click();
    await app.page.waitForURL(taskUrl);
    await waitForLiveView(app.page);
    await app.page.getByTestId("task-node-entrada").click();
    await expect(app.page.getByTestId("task-prompt-text")).toContainText("100 logins simultâneos");
    await shot(app.page, "task-proposal-answered");

    // Flow B: a decision suggested by the agent.
    await tasks.open(workspace.slug);
    await tasks.create({
      title: "Botão que não responde",
      prompt: "[bloqueio] O botão de salvar não responde.",
      pipeline: "Prompt único",
      project: "App",
    });
    await expect(tasks.status).toHaveText("Aguardando decisão", { timeout: 60_000 });
    // A block with nothing to ask is analysed; "Sugerir com IA" sits in the manual decision.
    await tasks.openManualDecision();
    await app.page.getByTestId("decision-suggest").click();
    await proposal.waitForProposal();
    await proposal.waitForAnswer();
    await expect(app.page.getByTestId("proposal-diagnosis")).toContainText("falta saber o navegador");
    await expect(app.page.getByTestId("proposal-decision-instructions")).toHaveValue(/\[desbloqueio\]/);
    await shot(app.page, "decision-proposal-review");
    await proposal.decide("retry");
    await expect(tasks.status).toHaveText("Concluída", { timeout: 60_000 });

    // Flow C: the pipeline improved from how its tasks went.
    await pipelines.open(workspace.slug);
    await app.page.getByTestId("pipeline-improve-Prompt único").click();
    await proposal.submitRequest({ project: "App", focus: "Verificar os testes." });
    await proposal.waitForAnswer();
    await expect(app.page.getByTestId("proposal-changes")).toContainText("Nenhuma tarefa verificou os testes");
    // The revision drawn against the pipeline as it is.
    await expect(app.page.getByTestId("proposal-diagram")).toBeVisible();
    await shot(app.page, "improve-proposal-review");
    await proposal.saveNotes();
    await proposal.reviewPipeline();
    await expect(pipelines.stageGates(0)).toHaveValue("{{projeto.teste}}");
    await pipelines.save();
    await expect(pipelines.version("Prompt único")).toHaveText("v2");

    await projects.open(workspace.slug);
    await app.page.goto(`/w/${workspace.slug}/proposals`);
    // Four tasks (one the round of the answers), the decision, the improvement, and the analysis
    // the block asked for by itself.
    await expect(app.page.getByTestId("proposals").locator("li")).toHaveCount(7);
    await shot(app.page, "proposals");
    await expectFitsPhone(app.page, "proposals");
  });
});
