/**
 * @section Landing
 * @flow A [done] The director builds the Nimbus workspace through the UI, with a real runner
 *   on the showcase CLI, and photographs the board, a running task, a decision, a job's
 *   audit, usage and the runners, light and dark, for the landing page
 * @flow B [done] It goes on for the documentation: the notifications panel while tasks run, a
 *   pipeline's diagram, and a Forgejo issue taken to a merged PR, for the integration's page
 *   and the quality of the deliveries
 *
 * Not part of the suite: it runs only under `make landing.shots` (E2E_DIRECTOR=1), on an
 * empty e2e database, and writes apps/pipe_maestro_web/priv/static/images/landing/.
 * Its names are fixed on purpose: they show on the landing page.
 */
import { execFileSync } from "node:child_process";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { hostname, tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { expect, test } from "@playwright/test";
import { bootstrapOperator, userPassword } from "../helpers/env";
import { createForgejoIssue, createForgejoRepo, fakeForgejo, forgejoState } from "../helpers/fakeForgejo";
import { issueLabelPayload, pullRequestClosedPayload, sendForgejoWebhook } from "../helpers/webhook";
import { RunnerProcess } from "../helpers/runnerProcess";
import { waitForLiveView } from "../helpers/liveView";
import { AppPage } from "../pages/AppPage";
import { BackofficePage } from "../pages/BackofficePage";
import { IntegrationsPage } from "../pages/IntegrationsPage";
import { NotificationsPage } from "../pages/NotificationsPage";
import { Timeline } from "../pages/JobsPage";
import { PipelinesPage } from "../pages/PipelinesPage";
import { ProjectsPage } from "../pages/ProjectsPage";
import { RunnersPage } from "../pages/RunnersPage";
import { TasksPage } from "../pages/TasksPage";
import { UsagePage } from "../pages/UsagePage";
import { capture, retext } from "./capture";
import {
  createCodeRoot,
  directory,
  issue,
  member,
  repository,
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

  test("photographs the platform for the landing page", async ({ page, browser, request }) => {
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
    await projects.create({ name: "Loja API", runner: runnerName, directory, setup: "make deps", test: "make test" });

    // The tasks: two that finish, one that stops with questions, two held mid-pipeline.
    const taskPage = new TasksPage(page);
    const start = async (task: ShowcaseTask) => {
      await taskPage.open(workspace.slug);
      return taskPage.create({ title: task.title, prompt: task.prompt, pipeline, project: "Loja API" });
    };

    const couponId = await start(tasks.coupon);
    await expect(taskPage.status).toHaveText("Concluída", { timeout: 120_000 });
    const shippingId = await start(tasks.shipping);
    await expect(taskPage.status).toHaveText("Concluída", { timeout: 120_000 });
    const exportId = await start(tasks.export);
    await expect(taskPage.status).toHaveText("Aguardando decisão", { timeout: 60_000 });
    const stockId = await start(tasks.stock);
    await expect(taskPage.stageNodeState("reproducao")).toHaveText("Executando", { timeout: 120_000 });
    const paginationId = await start(tasks.pagination);
    await expect(taskPage.stageNodeState("implementacao")).toHaveText("Executando", { timeout: 120_000 });

    // board: every column has a card, the runner online.
    await app.openBoard(workspace.slug, "tarefas");
    for (const id of [couponId, shippingId, exportId, stockId, paginationId]) {
      await expect(page.getByTestId(`board-task-${id}`)).toBeVisible();
    }
    await capture(page, "board");

    // task: the coupon task's reproduction stage: the steps of the stage, with
    // the run of the test it wrote open, failing for the reason the bug gives.
    await taskPage.show(workspace.slug, couponId);
    await taskPage.openStage("reproducao");
    const steps = new Timeline(await taskPage.openSteps("reproducao", 1));
    await steps.icons().last().click();
    await capture(page, "task", { top: "task-stage-panel" });

    // decision: the questions the agent asked, with its recommended option.
    await taskPage.show(workspace.slug, exportId);
    await taskPage.openDecision();
    await expect(taskPage.questionnaire()).toBeVisible();
    await capture(page, "decision", { top: "decision-panel" });

    // audit: the job of a finished stage.
    await taskPage.show(workspace.slug, couponId);
    await taskPage.openStage("implementacao");
    await page.getByTestId("stage-run-audit-implementacao-1").click();
    // The link opens the run's agent, in a drawer over the task, on its audit.
    await expect(page.getByTestId("job-audit")).toBeVisible();
    await waitForLiveView(page);
    await capture(page, "audit", { top: "job-audit" });

    // usage: the cost by stage and by origin.
    await new UsagePage(page).open(workspace.slug);
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

    // notifications: the bell's panel, with the held tasks running.
    await app.openBoard(workspace.slug);
    const bell = new NotificationsPage(page);
    await bell.open();
    await page.mouse.move(0, 0);
    await page.waitForTimeout(400);
    await capture(page, "notifications");
    await bell.close();

    // The held tasks finish before the runner goes.
    writeFileSync(join(showcaseDir, "release"), "");
    await taskPage.show(workspace.slug, paginationId);
    await expect(taskPage.status).toHaveText("Concluída", { timeout: 120_000 });
    await taskPage.show(workspace.slug, stockId);
    await expect(taskPage.status).toHaveText("Concluída", { timeout: 120_000 });

    // pipeline: the feature pipeline's diagram, its reviews side by side.
    await pipelines.open(workspace.slug);
    await pipelines.openPage("Nova funcionalidade");
    await expect(pipelines.diagram).toBeVisible();
    await capture(page, "pipeline");

    // The store's code gets an origin on the Nimbus Forgejo, and the bug pipeline delivers
    // in a pull request.
    const repo = join(root, directory);
    const origin = join(runner.configDir, "loja-api.git");
    execFileSync("git", ["init", "-q", "--bare", "-b", "main", origin], { stdio: "ignore" });
    execFileSync("git", ["-C", repo, "remote", "add", "origin", origin], { stdio: "ignore" });
    execFileSync("git", ["-C", repo, "push", "-q", "origin", "main"], { stdio: "ignore" });
    await createForgejoRepo(repository);

    await pipelines.open(workspace.slug);
    await pipelines.edit(pipeline);
    await pipelines.openEntry();
    await pipelines.openEntryTab("entrega");
    await page.getByTestId("pipeline-delivery").selectOption("pr");
    await pipelines.save();

    const integrations = new IntegrationsPage(page);
    await integrations.open(workspace.slug);
    await integrations.createTokenConnection("Forgejo da Nimbus");
    const { url: webhookUrl, secret } = await integrations.webhook();
    await integrations.linkRepo(repository, `Loja API (${directory})`);
    await page.getByTestId("trigger-new").click();
    await page.getByTestId("trigger-kind").selectOption("label");
    await page.getByTestId("trigger-label").fill("pipemaestro");
    await page.getByTestId("trigger-mode").selectOption("task");
    await page.getByTestId("trigger-pipeline").selectOption({ label: pipeline });
    await page.getByTestId("trigger-save").click();
    await expect(integrations.trigger({ kind: "label", label: "pipemaestro" })).toBeVisible();

    // A label on an issue: the task runs and its PR is merged.
    await createForgejoIssue({ repo: repository, ...issue });
    const labeled = await sendForgejoWebhook(request, {
      url: webhookUrl,
      secret,
      event: "issue_label",
      id: "nimbus-label-1",
      payload: issueLabelPayload(repository, issue, fakeForgejo.url),
    });
    expect(labeled.status()).toBe(202);

    const taskLink = async (): Promise<string | null> => {
      const state = await forgejoState(repository);
      const found = state.comments
        .map((comment: { body: string }) => comment.body.match(/\/w\/[^/]+\/tasks\/[0-9a-f-]+/))
        .find(Boolean);
      return found ? found[0] : null;
    };
    await expect.poll(taskLink, { timeout: 120_000 }).not.toBeNull();
    await page.goto((await taskLink()) as string);
    await waitForLiveView(page);
    await expect(taskPage.status).toHaveText("Concluída", { timeout: 180_000 });

    const [pull] = (await forgejoState(repository)).pulls;
    const merged = await sendForgejoWebhook(request, {
      url: webhookUrl,
      secret,
      event: "pull_request",
      id: "nimbus-merged-1",
      // Merged after a person's review, two hours after the PR was ready.
      payload: pullRequestClosedPayload(
        repository,
        { number: pull.number, branch: pull.head.ref, merged: true, at: new Date(Date.now() + 2 * 3_600_000) },
        fakeForgejo.url,
      ),
    });
    expect(merged.status()).toBe(202);

    // integrations: the connection, its repository and what the webhook delivered.
    await integrations.open(workspace.slug);
    await page.getByTestId("integration-link-forgejo-da-nimbus").click();
    await waitForLiveView(page);
    await integrations.openTab("entregas");
    await retext(page, [[fakeForgejo.url, "https://git.nimbus.dev"]]);
    await capture(page, "integrations");

    // quality: the delivered PR, accepted as the pipeline left it.
    const usage = new UsagePage(page);
    await expect(async () => {
      await usage.openTab(workspace.slug, "qualidade");
      await expect(usage.delivered).toHaveText(/\b1\s*$/, { timeout: 1_000 });
    }).toPass({ timeout: 30_000 });
    await capture(page, "quality");
  });
});
