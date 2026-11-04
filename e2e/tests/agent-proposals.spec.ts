/**
 * @section Tarefas e pipelines
 * @flow A [done] A member asks the agent to write a task from an idea; the proposal opens the new-task form filled with it, and the task runs
 * @flow B [done] A task stops for a decision; the agent suggests one, and applying it (retry with its instructions) lets the task finish
 * @flow C [done] An admin asks the agent to improve a pipeline from how its tasks went; the notes are saved and the revised pipeline becomes its next version
 */
import { expect, test } from "@playwright/test";
import { bootstrapOperator, uniqueSuffix, userPassword } from "../helpers/env";
import { RunnerProcess } from "../helpers/runnerProcess";
import { shot } from "../helpers/screenshots";
import { AppPage } from "../pages/AppPage";
import { BackofficePage } from "../pages/BackofficePage";
import { PipelinesPage } from "../pages/PipelinesPage";
import { ProjectsPage } from "../pages/ProjectsPage";
import { ProposalPage } from "../pages/ProposalPage";
import { RunnersPage } from "../pages/RunnersPage";
import { TasksPage } from "../pages/TasksPage";

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
    await projects.create({ name: "App", directory: "app" });

    const proposal = new ProposalPage(app.page);
    const tasks = new TasksPage(app.page);

    // Flow A: a task written from an idea.
    await tasks.open(workspace.slug);
    await app.page.getByTestId("task-generate").click();
    await app.page.getByTestId("proposal-request-text").fill("O login trava quando muita gente entra junto.");
    await shot(app.page, "task-proposal-request");
    await proposal.submitRequest({ runner: runnerName, directory: "app" });
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

    // Flow B: a decision suggested by the agent.
    await tasks.open(workspace.slug);
    await tasks.create({
      title: "Botão que não responde",
      prompt: "[bloqueio] O botão de salvar não responde.",
      pipeline: "Prompt único",
      runner: runnerName,
      directory: "app",
    });
    await expect(tasks.status).toHaveText("Aguardando decisão", { timeout: 60_000 });
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
    await proposal.submitRequest({ runner: runnerName, directory: "app", focus: "Verificar os testes." });
    await proposal.waitForAnswer();
    await expect(app.page.getByTestId("proposal-changes")).toContainText("Nenhuma tarefa verificou os testes");
    await shot(app.page, "improve-proposal-review");
    await proposal.saveNotes();
    await proposal.reviewPipeline();
    await expect(pipelines.stageGates(0)).toHaveValue("{{projeto.teste}}");
    await pipelines.save();
    await expect(pipelines.version("Prompt único")).toHaveText("v2");

    await projects.open(workspace.slug);
    await app.page.goto(`/w/${workspace.slug}/proposals`);
    await expect(app.page.getByTestId("proposals").locator("li")).toHaveCount(3);
    await shot(app.page, "proposals");
  });
});
