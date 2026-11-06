/**
 * @section Tarefas e pipelines
 * @flow A A stage the agent blocks asks structured questions; the member picks the recommended option, two in the multiple-choice one, writes in "Outro", reviews, confirms, and the task succeeds
 * @flow B A stage that fails its attempts pauses; the agent analyses the failure on its own ("analisando…"), then the diagnosis and its question show; the member picks "Tentar sem falha", confirms, and the task succeeds
 * @flow C The same questionnaire is answered from the Decisions page
 */
import { expect, test, type Browser, type Page } from "@playwright/test";
import { bootstrapOperator, uniqueSuffix, userPassword } from "../helpers/env";
import { RunnerProcess } from "../helpers/runnerProcess";
import { waitForLiveView } from "../helpers/liveView";
import { shot } from "../helpers/screenshots";
import { AppPage } from "../pages/AppPage";
import { BackofficePage } from "../pages/BackofficePage";
import { PipelinesPage } from "../pages/PipelinesPage";
import { ProjectsPage } from "../pages/ProjectsPage";
import { RunnersPage } from "../pages/RunnersPage";
import { TasksPage } from "../pages/TasksPage";

/**
 * A member signed in to a new workspace with the ready-made pipelines and a
 * runner online; returns the member's page, the workspace slug and the runner.
 */
async function setUp(
  page: Page,
  browser: Browser,
  runner: RunnerProcess,
): Promise<{ app: AppPage; slug: string; runnerName: string }> {
  const suffix = uniqueSuffix();
  const workspace = { name: `Perguntas ${suffix}`, slug: `perguntas-${suffix}` };
  const user = { name: `Rita ${suffix}`, email: `rita-${suffix}@e2e.test` };
  const runnerName = `perguntas-${suffix}`;

  const backoffice = new BackofficePage(page);
  await backoffice.signInExpectingSuccess(bootstrapOperator.email, bootstrapOperator.password);
  await backoffice.createWorkspace(workspace.name);
  await backoffice.createMember(user.name, user.email, userPassword);

  const context = await browser.newContext();
  const app = new AppPage(await context.newPage());
  await app.signIn(user.email, userPassword);
  await app.expectBoard(workspace.name);

  const root = runner.createCodeRoot();
  runner.start("runner.login", ["--url", app.page.url().replace(/\/w\/.*$/, "")]);
  const [, code] = await runner.waitFor(/digite o código:\s+([A-Z]{4}-[A-Z]{4})/);
  await new RunnersPage(app.page).approve(code, runnerName);
  expect(await runner.waitForExit()).toBe(0);

  runner.start("runner.start", ["--root", root]);
  await runner.waitFor(/Online como/);

  const projects = new ProjectsPage(app.page);
  await projects.open(workspace.slug);
  await projects.create({ name: "Notas", runner: runnerName, directory: "notas" });

  const pipelines = new PipelinesPage(app.page);
  await pipelines.open(workspace.slug);
  await pipelines.createDefaults();

  return { app, slug: workspace.slug, runnerName };
}

test.describe("Decision questionnaire", () => {
  // Real CLI processes: the first one may compile the runner app.
  test.setTimeout(240_000);

  let runner: RunnerProcess;

  test.afterEach(() => runner?.cleanup());

  test("a blocked stage's questions are answered and the task goes on", async ({ page, browser }) => {
    runner = new RunnerProcess();
    const { app, slug, runnerName } = await setUp(page, browser, runner);
    const tasks = new TasksPage(app.page);

    // Flow A: the agent asks two questions (one multiple-choice, one with a preview).
    await tasks.open(slug);
    await tasks.create({
      title: "Tela branca",
      prompt: "Às vezes a tela fica branca. [perguntas]",
      pipeline: "Prompt único",
      project: "Notas",
    });

    await expect(tasks.status).toHaveText("Aguardando decisão");
    await expect(tasks.questionnaire()).toBeVisible();
    await expect(tasks.question(0)).toBeVisible();
    await expect(tasks.question(1)).toBeVisible();
    await expect(tasks.questionnairePart("submit")).toBeDisabled();
    await expect(tasks.questionnairePart("progress")).toContainText("0 de 2");
    await shot(app.page, "questionnaire-blocked");
    // A narrow screen: options in one column, buttons full width.
    await app.page.setViewportSize({ width: 390, height: 844 });
    await shot(app.page, "questionnaire-blocked-narrow");
    await app.page.setViewportSize({ width: 1440, height: 900 });

    // The recommended option comes first.
    await tasks.answerQuestion(0, 0);
    await expect(tasks.questionnairePart("progress")).toContainText("1 de 2");
    await expect(tasks.questionnairePart("submit")).toBeDisabled();

    // Two choices in the multiple-choice question, and Other.
    await tasks.answerQuestion(1, 0);
    await tasks.answerQuestion(1, 1);
    await tasks.fillOther(1, "[desbloqueio] e no menu");
    await expect(tasks.questionnairePart("progress")).toContainText("2 de 2");

    await tasks.submitAnswers();
    await expect(tasks.questionnairePart("review")).toContainText("[desbloqueio] e no menu");
    await shot(app.page, "questionnaire-review");

    // Back keeps the answers.
    await tasks.questionnairePart("back").click();
    await expect(tasks.questionnairePart("progress")).toContainText("2 de 2");
    await tasks.submitAnswers();
    await tasks.confirmAnswers();

    await expect(tasks.status).toHaveText("Concluída");
    await expect(tasks.stageRun("executar", 2)).toContainText("[desbloqueio] e no menu");
    await expect(app.page.getByTestId("task-decision-answers-0")).toContainText("[desbloqueio] e no menu");
    await shot(app.page, "questionnaire-history");
  });

  test("a failure is analysed by the agent, and its question takes the task on", async ({
    page,
    browser,
  }) => {
    runner = new RunnerProcess();
    const { app, slug, runnerName } = await setUp(page, browser, runner);
    const tasks = new TasksPage(app.page);

    // Flow B: the stage fails every attempt; the analysis starts on its own.
    await tasks.open(slug);
    await tasks.create({
      title: "Falha no build",
      prompt: "O build quebra. [falha]",
      pipeline: "Prompt único",
      project: "Notas",
    });

    await expect(tasks.status).toHaveText("Aguardando decisão", { timeout: 60_000 });
    // The manual decision is there while the agent analyses.
    await expect(app.page.getByTestId("decision-manual")).toBeVisible();
    await expect(tasks.questionnairePart("diagnosis")).toBeVisible({ timeout: 60_000 });
    await expect(tasks.questionnairePart("analyzing")).toBeHidden();
    await shot(app.page, "questionnaire-analysis");

    await tasks.answerQuestion(0, 0);
    await expect(tasks.questionOption(0, 0)).toContainText("Tentar sem falha");
    await tasks.submitAnswers();
    await tasks.confirmAnswers();

    await expect(tasks.status).toHaveText("Concluída", { timeout: 60_000 });
  });

  test("the questionnaire is answered from the Decisions page", async ({ page, browser }) => {
    runner = new RunnerProcess();
    const { app, slug, runnerName } = await setUp(page, browser, runner);
    const tasks = new TasksPage(app.page);

    // Flow C: the same questions, answered from the list.
    await tasks.open(slug);
    const taskId = await tasks.create({
      title: "Menu some",
      prompt: "O menu desaparece. [perguntas]",
      pipeline: "Prompt único",
      project: "Notas",
    });
    await expect(tasks.status).toHaveText("Aguardando decisão");

    await app.page.getByTestId("sidebar-decisions").click();
    await waitForLiveView(app.page);
    await expect(tasks.questionnaire(taskId)).toBeVisible();
    await expect(tasks.questionnairePart("submit", taskId)).toBeDisabled();
    await shot(app.page, "questionnaire-decisions");

    await tasks.answerQuestion(0, 0, taskId);
    await tasks.answerQuestion(1, 0, taskId);
    await tasks.fillOther(1, "[desbloqueio]", taskId);
    await tasks.submitAnswers(taskId);
    await tasks.confirmAnswers(taskId);

    await expect(app.page.getByTestId(`decision-${taskId}`)).toBeHidden();
    await tasks.show(slug, taskId);
    await expect(tasks.status).toHaveText("Concluída");
  });
});
