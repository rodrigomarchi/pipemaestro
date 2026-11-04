/**
 * @section Landing
 * @flow A [done] The director builds the Nimbus workspace through the UI, with a real runner
 *   on the showcase CLI, and photographs the board, a running task, a decision, a job's
 *   audit, usage and the runners, light and dark, for the landing page
 *
 * Not part of the suite: it runs only under `make landing.shots` (E2E_DIRECTOR=1), on an
 * empty e2e database, and writes apps/pipe_maestro_web/priv/static/images/landing/.
 * Its names are fixed on purpose: they show on the landing page.
 */
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { hostname, tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { expect, test } from "@playwright/test";
import { bootstrapOperator, userPassword } from "../helpers/env";
import { RunnerProcess } from "../helpers/runnerProcess";
import { waitForLiveView } from "../helpers/liveView";
import { AppPage } from "../pages/AppPage";
import { BackofficePage } from "../pages/BackofficePage";
import { Timeline } from "../pages/JobsPage";
import { PipelinesPage } from "../pages/PipelinesPage";
import { ProjectsPage } from "../pages/ProjectsPage";
import { RunnersPage } from "../pages/RunnersPage";
import { TasksPage } from "../pages/TasksPage";
import { capture, retext } from "./capture";
import {
  createCodeRoot,
  directory,
  member,
  runnerName,
  tasks,
  workspace,
  writeScenes,
  type ShowcaseTask,
} from "./scenario";

const showcaseClaude = resolve(process.cwd(), "director", "support", "showcase_claude");
const pipeline = "Correção de bug";

test.describe("Landing director", () => {
  let runner: RunnerProcess | undefined;
  let showcaseDir: string | undefined;

  test.afterEach(() => {
    if (showcaseDir) writeFileSync(join(showcaseDir, "release"), "");
    runner?.cleanup();
    if (showcaseDir) rmSync(showcaseDir, { recursive: true, force: true });
  });

  test("photographs the platform for the landing page", async ({ page, browser }) => {
    showcaseDir = mkdtempSync(join(tmpdir(), "nimbus-showcase-"));
    const scenes = join(showcaseDir, "scenes.txt");
    writeScenes(scenes);

    // The operator opens the workspace and adds Marina.
    const operatorContext = await browser.newContext();
    const backoffice = new BackofficePage(await operatorContext.newPage());
    await backoffice.signInExpectingSuccess(bootstrapOperator.email, bootstrapOperator.password);
    await backoffice.createWorkspace(workspace.name, workspace.slug);
    await backoffice.createMember(member.name, member.email, userPassword);
    await operatorContext.close();

    const app = new AppPage(page);
    await app.signIn(member.email, userPassword);
    await app.expectBoard(workspace.name);

    // Marina's laptop: a runner on the showcase CLI, over the store's code.
    runner = new RunnerProcess({
      claudeBin: showcaseClaude,
      configPrefix: "nimbus-",
      env: { SHOWCASE_DIR: showcaseDir, SHOWCASE_SCENES: scenes },
    });
    const root = createCodeRoot(join(runner.configDir, "src"));
    runner.start("runner.login", ["--url", page.url().replace(/\/w\/.*$/, ""), "--capacity", "4"]);
    const [, code] = await runner.waitFor(/digite o código:\s+([A-Z]{4}-[A-Z]{4})/);
    await new RunnersPage(page).approve(code, runnerName);
    expect(await runner.waitForExit()).toBe(0);
    runner.start("runner.start", ["--root", root]);
    await runner.waitFor(/Online como/);

    const pipelines = new PipelinesPage(page);
    await pipelines.open(workspace.slug);
    await pipelines.createDefaults();

    const projects = new ProjectsPage(page);
    await projects.open(workspace.slug);
    await projects.create({ name: "Loja API", directory, setup: "make deps", test: "make test" });

    // The tasks: two that finish, one that stops with questions, two held mid-pipeline.
    const taskPage = new TasksPage(page);
    const start = async (task: ShowcaseTask) => {
      await taskPage.open(workspace.slug);
      return taskPage.create({ title: task.title, prompt: task.prompt, pipeline, runner: runnerName, directory });
    };

    const couponId = await start(tasks.coupon);
    await expect(taskPage.status).toHaveText("Concluída", { timeout: 120_000 });
    const shippingId = await start(tasks.shipping);
    await expect(taskPage.status).toHaveText("Concluída", { timeout: 120_000 });
    const exportId = await start(tasks.export);
    await expect(taskPage.status).toHaveText("Aguardando decisão", { timeout: 60_000 });
    const stockId = await start(tasks.stock);
    await expect(taskPage.stageRunStatus("reproducao", 1)).toHaveText("Executando", { timeout: 120_000 });
    const paginationId = await start(tasks.pagination);
    await expect(taskPage.stageRunStatus("implementacao", 1)).toHaveText("Executando", { timeout: 120_000 });

    // board: every column has a card, the runner online.
    await app.openBoard(workspace.slug);
    for (const id of [couponId, shippingId, exportId, stockId, paginationId]) {
      await expect(page.getByTestId(`board-task-${id}`)).toBeVisible();
    }
    await capture(page, "board");

    // task: the held task from its third stage: the test it wrote, the steps of
    // that stage with the test run open, and the stage running live.
    await taskPage.show(workspace.slug, paginationId);
    const steps = new Timeline(await taskPage.openSteps("reproducao", 1));
    await steps.icons().last().click();
    await capture(page, "task", { top: "stage-reproducao" });

    // decision: the questions the agent asked, with its recommended option.
    await taskPage.show(workspace.slug, exportId);
    await expect(page.getByTestId("decision-panel")).toBeVisible();
    await expect(taskPage.questionnaire()).toBeVisible();
    await capture(page, "decision", { top: "decision-panel" });

    // audit: the job of a finished stage.
    await taskPage.show(workspace.slug, couponId);
    await page.getByTestId("stage-run-audit-implementacao-1").click();
    await expect(page.getByTestId("job-audit")).toBeVisible();
    await waitForLiveView(page);
    await capture(page, "audit", { top: "job-audit" });

    // usage: the cost by stage and by origin.
    await page.getByTestId("sidebar-usage").click();
    await expect(page.getByTestId("usage-by-runner")).toContainText(runnerName);
    await waitForLiveView(page);
    await capture(page, "usage");

    // runners: Marina's laptop, online.
    const runners = new RunnersPage(page);
    await runners.open(workspace.slug);
    await expect(runners.status(runnerName)).toBeVisible();
    await retext(page, [
      [hostname().replace(/\.local$/, ""), "MacBook-Pro-de-Marina"],
      [new URL(page.url()).origin, "https://app.pipemaestro.dev"],
    ]);
    await capture(page, "runners");

    // The held tasks finish before the runner goes.
    writeFileSync(join(showcaseDir, "release"), "");
    await taskPage.show(workspace.slug, paginationId);
    await expect(taskPage.status).toHaveText("Concluída", { timeout: 120_000 });
    await taskPage.show(workspace.slug, stockId);
    await expect(taskPage.status).toHaveText("Concluída", { timeout: 120_000 });
  });
});
