/**
 * @section Runners
 * @flow A [done] A runner stopped in the middle of a stage comes back: the stage is shown "Perdida (runner)" and runs again in the same attempt, without spending one; the runner's events show the lost job
 */
import { expect, test } from "@playwright/test";
import { bootstrapOperator, uniqueSuffix, userPassword } from "../helpers/env";
import { RunnerProcess } from "../helpers/runnerProcess";
import { shot } from "../helpers/screenshots";
import { AppPage } from "../pages/AppPage";
import { BackofficePage } from "../pages/BackofficePage";
import { PipelinesPage } from "../pages/PipelinesPage";
import { ProjectsPage } from "../pages/ProjectsPage";
import { RunnersPage } from "../pages/RunnersPage";
import { TasksPage } from "../pages/TasksPage";

test.describe("Runner restart", () => {
  // Real CLI processes: the first one may compile the runner app.
  test.setTimeout(240_000);

  let runner: RunnerProcess;

  test.afterEach(() => runner?.cleanup());

  test("a stage lost by a restarted runner runs again without spending an attempt", async ({ page, browser }) => {
    const suffix = uniqueSuffix();
    const workspace = { name: `Reinício ${suffix}`, slug: `reinicio-${suffix}` };
    const user = { name: `Rita ${suffix}`, email: `rita-${suffix}@e2e.test` };
    const runnerName = `reinicio-${suffix}`;

    const backoffice = new BackofficePage(page);
    await backoffice.signInExpectingSuccess(bootstrapOperator.email, bootstrapOperator.password);
    await backoffice.createWorkspace(workspace.name);
    await backoffice.createMember(user.name, user.email, userPassword);

    const context = await browser.newContext();
    const app = new AppPage(await context.newPage());
    await app.signIn(user.email, userPassword);
    await app.expectBoard(workspace.name);
    const runners = new RunnersPage(app.page);

    runner = new RunnerProcess();
    const root = runner.createCodeRoot();
    runner.start("runner.login", ["--url", app.page.url().replace(/\/w\/.*$/, "")]);
    const [, code] = await runner.waitFor(/digite o código:\s+([A-Z]{4}-[A-Z]{4})/);
    await runners.approve(code, runnerName);
    expect(await runner.waitForExit()).toBe(0);

    runner.start("runner.start", ["--root", root]);
    await runner.waitFor(/Online como/);

    const projects = new ProjectsPage(app.page);
    await projects.open(workspace.slug);
    await projects.create({ name: "Notas", runner: runnerName, directory: "notas" });
    const pipelines = new PipelinesPage(app.page);
    await pipelines.open(workspace.slug);
    await pipelines.createDefaults();

    const tasks = new TasksPage(app.page);
    await tasks.open(workspace.slug);
    const taskId = await tasks.create({
      title: "Interrompida pelo runner",
      prompt: "Leva tempo. [lento]",
      pipeline: "Prompt único",
      project: "Notas",
    });
    await expect(tasks.stageRunStatus("executar", 1)).toHaveText("Executando");

    // The runner goes down in the middle of the stage and comes back.
    runner.stop();
    await runner.waitForExit();
    runner.start("runner.start", ["--root", root]);
    await runner.waitFor(/Online como/);

    await tasks.show(workspace.slug, taskId);
    await expect(tasks.stageRunStatus("executar", 1)).toHaveText("Perdida (runner)");
    await expect(tasks.stageRunLost("executar", 1)).toContainText("o runner reiniciou");
    await expect(tasks.requeuedRunStatus("executar", 1, 1)).toHaveText("Executando");
    await expect(tasks.stageRun("executar", 2)).toHaveCount(0);
    await expect(tasks.status).toHaveText("Executando");
    await shot(app.page, "task-stage-lost");

    await runners.openRunner(workspace.slug, runnerName);
    await runners.openTab("eventos");
    await runners.filterEvents("connection");
    await expect(runners.event("job_lost").first()).toBeVisible();
    await shot(app.page, "runner-events-job-lost");

    await app.page.goto(`/w/${workspace.slug}/tasks/${taskId}`);
    await app.page.getByTestId("task-cancel").click();
    // The runner stops the running agent first: SIGTERM, then SIGKILL after 5 s.
    await expect(tasks.status).toHaveText("Cancelada", { timeout: 15_000 });
  });
});
