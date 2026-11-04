/**
 * @section Tarefas e pipelines
 * @flow A [done] The board's "needs attention" card follows the runner live: the limit alert shows once the running task reports its account near the limit, and the offline alert shows as soon as the runner stops, without reloading
 * @flow B [done] A running task whose runner is offline says so on its own page
 */
import { expect, test } from "@playwright/test";
import { bootstrapOperator, uniqueSuffix, userPassword } from "../helpers/env";
import { RunnerProcess } from "../helpers/runnerProcess";
import { shot } from "../helpers/screenshots";
import { AppPage } from "../pages/AppPage";
import { BackofficePage } from "../pages/BackofficePage";
import { PipelinesPage } from "../pages/PipelinesPage";
import { RunnersPage } from "../pages/RunnersPage";
import { TasksPage } from "../pages/TasksPage";

test.describe("Board alerts", () => {
  // Real CLI processes: the first one may compile the runner app.
  test.setTimeout(240_000);

  let runner: RunnerProcess;

  test.afterEach(() => runner?.cleanup());

  test("the board's alerts follow the runner, live", async ({ page, browser }) => {
    const suffix = uniqueSuffix();
    const workspace = { name: `Alertas ${suffix}`, slug: `alertas-${suffix}` };
    const user = { name: `Alice ${suffix}`, email: `alice-${suffix}@e2e.test` };
    const runnerName = `alerta-${suffix}`;

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

    // The board stays open in its own tab while the task starts in another.
    const board = new AppPage(await context.newPage());
    await board.openBoard(workspace.slug);

    const tasks = new TasksPage(app.page);
    await tasks.open(workspace.slug);
    const taskId = await tasks.create({
      title: "Demora perto do limite",
      prompt: "Trabalhe devagar. [lento] [limite]",
      pipeline: "Prompt único",
      runner: runnerName,
      directory: "app",
    });
    await expect(tasks.status).toHaveText("Executando");

    // Flow A: the account near its limit, then the runner gone, without reloading.
    await expect(board.boardAlert("limit", taskId)).toContainText(runnerName);
    await expect(board.boardAlert("offline", taskId)).toHaveCount(0);

    runner.stop();
    await expect(board.boardAlert("offline", taskId)).toContainText(runnerName);
    await shot(board.page, "board-alertas");

    // Flow B: the task's own page says why it is stuck.
    await tasks.show(workspace.slug, taskId);
    await expect(tasks.status).toHaveText("Executando");
    await expect(tasks.runnerOffline).toContainText(runnerName);
    await shot(app.page, "task-runner-offline");

    await context.close();
  });
});
