/**
 * @section Tarefas e pipelines
 * @flow A [done] What the agent copies to $CP_FILES_DIR reaches the task: an image as a thumbnail that opens, a CSV downloaded as an attachment, every file of the task in the "Anexos" tab, and nothing of it in the worktree's git
 */
import { existsSync } from "node:fs";
import { execFileSync } from "node:child_process";
import { join } from "node:path";
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

test.describe("Task files", () => {
  // Real CLI processes: the first one may compile the runner app.
  test.setTimeout(240_000);

  let runner: RunnerProcess;

  test.afterEach(() => runner?.cleanup());

  test("the files a stage leaves in CP_FILES_DIR show on the task", async ({ page, browser }) => {
    const suffix = uniqueSuffix();
    const workspace = { name: `Anexos ${suffix}`, slug: `anexos-${suffix}` };
    const user = { name: `Clara ${suffix}`, email: `clara-${suffix}@e2e.test` };
    const runnerName = `anexos-${suffix}`;

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

    const projects = new ProjectsPage(app.page);
    await projects.open(workspace.slug);
    await projects.create({ name: "App", runner: runnerName, directory: "app" });

    const pipelines = new PipelinesPage(app.page);
    await pipelines.open(workspace.slug);
    await pipelines.createDefaults();

    const tasks = new TasksPage(app.page);
    await tasks.open(workspace.slug);
    const taskId = await tasks.create({
      title: "Telas do login",
      prompt: "Tire as telas do login e gere o relatório. [arquivos]",
      pipeline: "Prompt único",
      project: "App",
    });

    await expect(tasks.status).toHaveText("Concluída", { timeout: 60_000 });

    // The attempt's files, beside its artifact: the image as a thumbnail that
    // loaded, the CSV as a link; the symlink the agent left is not there.
    await tasks.openStage("executar");
    await expect(tasks.stageRunFiles("executar", 1)).toBeVisible();
    await expect(tasks.stageRunFile("executar", 1, "a.png")).toBeVisible();
    await expect(tasks.stageRunFile("executar", 1, "dados/r.csv")).toBeVisible();
    await expect(tasks.stageRunFile("executar", 1, "atalho.png")).toHaveCount(0);
    await expect(tasks.stageRunFilesFailed("executar", 1)).toHaveCount(0);

    const thumb = tasks.stageRunFileThumb("executar", 1, "a.png");
    await expect(thumb).toBeVisible();
    await expect
      .poll(() => thumb.evaluate((img: HTMLImageElement) => img.complete && img.naturalWidth))
      .toBeGreaterThan(0);
    await expect(tasks.stageRunFileThumb("executar", 1, "dados/r.csv")).toHaveCount(0);
    await shot(tasks.stageRunFiles("executar", 1), "stage-run-files");

    // The image opens in the browser; the CSV downloads, never shown.
    const imageHref = await tasks.stageRunFileDownload("executar", 1, "a.png").getAttribute("href");
    const image = await app.page.request.get(imageHref!);
    expect(image.status()).toBe(200);
    expect(image.headers()["content-type"]).toContain("image/png");
    expect(image.headers()["content-disposition"]).toMatch(/^inline;/);
    expect(image.headers()["x-content-type-options"]).toBe("nosniff");

    const csvHref = await tasks.stageRunFileDownload("executar", 1, "dados/r.csv").getAttribute("href");
    const csv = await app.page.request.get(csvHref!);
    expect(csv.status()).toBe(200);
    expect(csv.headers()["content-disposition"]).toMatch(/^attachment;/);
    expect(await csv.text()).toBe("tela,ok\nlogin,sim\n");

    // Someone without a session gets nothing: sent to sign in, not the file.
    const stranger = await browser.newContext();
    const refused = await stranger.request.get(csvHref!, { maxRedirects: 0 });
    expect(refused.status()).toBe(302);
    expect(refused.headers()["location"]).toContain("/login");
    await stranger.close();

    // The "Anexos" tab gathers every file of the task, by stage and attempt.
    await expect(tasks.tabCount("anexos")).toHaveText("2");
    await tasks.openTab("anexos");
    await expect(tasks.noAttachments).toHaveCount(0);
    await expect(tasks.attachments("executar", 1)).toContainText("a.png");
    await expect(tasks.attachments("executar", 1)).toContainText("dados/r.csv");
    await shot(app.page, "task-attachments");

    // None of it went into the worktree, nor into its git.
    const worktree = join(runner.workdir, "worktrees", taskId);
    expect(existsSync(join(worktree, "a.png"))).toBe(false);
    const tracked = execFileSync("git", ["-C", worktree, "ls-files"], { encoding: "utf8" });
    expect(tracked).not.toContain("a.png");
    expect(tracked).not.toContain("r.csv");

    await context.close();
  });
});
