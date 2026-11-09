/**
 * @section Tarefas e pipelines
 * @flow A The "Etapas" tab shows the pipeline vertically, only each stage's state: nothing a stage produced is on the page until its panel opens
 * @flow B A stage's node opens a panel 90% wide, kept in the URL (`?etapa=`): live while the stage runs, then its artifact first, without a reload
 * @flow C The panel closes by its button, Escape and the browser's back; a link with the stage opens it again
 * @flow D A task waiting for a decision shows a banner over the pipeline; "Decidir" opens the waiting stage, where the decision is taken
 * @flow E On a phone, one column, and the panel takes the whole width
 */
import { expect, test, type Browser, type Page } from "@playwright/test";
import { bootstrapOperator, uniqueSuffix, userPassword } from "../helpers/env";
import { RunnerProcess } from "../helpers/runnerProcess";
import { waitForLiveView } from "../helpers/liveView";
import { expectFitsPhone } from "../helpers/phone";
import { shot } from "../helpers/screenshots";
import { AppPage } from "../pages/AppPage";
import { BackofficePage } from "../pages/BackofficePage";
import { PipelinesPage } from "../pages/PipelinesPage";
import { ProjectsPage } from "../pages/ProjectsPage";
import { RunnersPage } from "../pages/RunnersPage";
import { TasksPage } from "../pages/TasksPage";

/**
 * A member signed in to a new workspace with the ready-made pipelines and a
 * runner online; returns the member's page and the workspace slug.
 */
async function setUp(page: Page, browser: Browser, runner: RunnerProcess) {
  const suffix = uniqueSuffix();
  const workspace = { name: `Painel ${suffix}`, slug: `painel-${suffix}` };
  const user = { name: `Lia ${suffix}`, email: `lia-${suffix}@e2e.test` };
  const runnerName = `painel-${suffix}`;

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

  return { app, slug: workspace.slug };
}

test.describe("Task stage panel", () => {
  // Real CLI processes: the first one may compile the runner app.
  test.setTimeout(240_000);

  let runner: RunnerProcess;

  test.afterEach(() => runner?.cleanup());

  test("the pipeline is light; a stage opens in a wide panel, live and then finished", async ({
    page,
    browser,
  }) => {
    runner = new RunnerProcess();
    const { app, slug } = await setUp(page, browser, runner);
    const tasks = new TasksPage(app.page);

    // "[lento]": the fake agent takes 30 s, so the stage is seen running.
    await tasks.open(slug);
    const taskId = await tasks.create({
      title: "Revisar a tela de login",
      prompt: "Revise a tela de login. [lento]",
      pipeline: "Prompt único",
      project: "Notas",
    });

    // Flow A: the pipeline, vertical, with the stage's state and nothing else.
    await expect(tasks.overview()).toBeVisible();
    await expect(tasks.stageNodeState("executar")).toHaveText("Executando");
    await expect(tasks.stagePanel()).toBeHidden();
    await expect(tasks.liveEvents()).toHaveCount(0);
    await expect(app.page.getByTestId("task-sidebar")).toHaveCount(0);
    await shot(app.page, "task-overview");

    // Flow B: the running stage's panel, 90% of the screen, live.
    await tasks.openStage("executar");
    const panel = await tasks.stagePanel().boundingBox();
    const viewport = app.page.viewportSize();
    expect(panel && viewport && panel.width / viewport.width).toBeGreaterThanOrEqual(0.85);
    await expect(tasks.stagePanel().getByTestId("task-events")).toBeVisible();
    // The message, pause and interruption, in the panel of the stage it is on.
    await expect(tasks.stagePanel().getByTestId("task-interrupt")).toBeVisible();
    await expect(tasks.stagePanel().getByTestId("stage-run-spent-executar-1")).toContainText("até agora");
    await shot(app.page, "task-stage-panel-live");

    // It ends while open: the artifact takes the place of the live steps.
    await expect(tasks.status).toHaveText("Concluída", { timeout: 60_000 });
    await expect(tasks.stageRunArtifact("executar", 1)).toContainText("Artefato do fake_claude");
    await expect(tasks.liveEvents()).toHaveCount(0);
    await shot(app.page, "task-stage-panel-finished");

    // Flow C: closed by Escape, by its button and by the browser's back.
    await tasks.closeStageWithEscape();
    await tasks.openStage("executar");
    await tasks.closeStage();
    await tasks.openStage("executar");
    await app.page.goBack();
    await tasks.expectStageClosed();

    // A link with the stage opens its panel.
    await app.page.goto(`/w/${slug}/tasks/${taskId}?etapa=executar`);
    await waitForLiveView(app.page);
    await expect(tasks.stagePanel()).toBeVisible();
    await expect(tasks.stageRunArtifact("executar", 1)).toBeVisible();

    // Flow E: on a phone, the panel takes the whole width and nothing overflows.
    await expectFitsPhone(app.page, "task-stage-panel");
    await tasks.closeStage();
    await expectFitsPhone(app.page, "task-overview");
  });

  test("a pending decision is taken from the waiting stage's panel", async ({ page, browser }) => {
    runner = new RunnerProcess();
    const { app, slug } = await setUp(page, browser, runner);
    const tasks = new TasksPage(app.page);

    await tasks.open(slug);
    await tasks.create({
      title: "Botão sem resposta",
      prompt: "O botão não responde. [bloqueio]",
      pipeline: "Prompt único",
      project: "Notas",
    });

    // Flow D: the banner over the pipeline, then the stage's panel with the decision.
    await expect(tasks.status).toHaveText("Aguardando decisão");
    await expect(tasks.decisionBanner()).toContainText("navegador");
    await expect(tasks.stageNodeState("executar")).toHaveText("Aguardando decisão");
    await shot(app.page, "task-decision-banner");

    await tasks.openDecision();
    await expect(tasks.stagePanel().getByTestId("decision-reason")).toContainText("navegador");
    await shot(app.page, "task-stage-panel-decision");

    await tasks.retryWith("É no Safari. [desbloqueio]");
    await expect(tasks.status).toHaveText("Concluída", { timeout: 60_000 });
    await expect(tasks.decisionBanner()).toHaveCount(0);

    // Two attempts: the latest shows, the first a click away.
    await expect(tasks.stageRun("executar", 2)).toBeVisible();
    await tasks.selectAttempt("executar", 1);
  });
});
