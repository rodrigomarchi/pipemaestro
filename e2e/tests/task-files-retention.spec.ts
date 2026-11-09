/**
 * @section Tarefas e pipelines
 * @flow A [done] An operator sets a workspace's retention and file quota in the backoffice; its page shows the files against the quota, and the members' usage page shows the same, read only, below the usage
 * @flow B [done] Once the workspace's quota is full, the files a stage leaves are refused with their own warning, and the task ends as it would without them
 * @flow C [done] Past the retention, a file keeps its name with "removido pela retenção" and no link (its download answers 410), and the stage's steps stay with only their metadata and a notice
 */
import { expect, test } from "@playwright/test";
import { bootstrapOperator, uniqueSuffix, userPassword } from "../helpers/env";
import { expireRetention, inflateJobFile } from "../helpers/e2eState";
import { RunnerProcess } from "../helpers/runnerProcess";
import { shot } from "../helpers/screenshots";
import { AppPage } from "../pages/AppPage";
import { BackofficePage } from "../pages/BackofficePage";
import { PipelinesPage } from "../pages/PipelinesPage";
import { ProjectsPage } from "../pages/ProjectsPage";
import { RunnersPage } from "../pages/RunnersPage";
import { TasksPage } from "../pages/TasksPage";
import { UsagePage } from "../pages/UsagePage";

test.describe("Task files retention", () => {
  // Real CLI processes: the first one may compile the runner app.
  test.setTimeout(300_000);

  let runner: RunnerProcess;

  test.afterEach(() => runner?.cleanup());

  test("the workspace's quota and retention reach its files and its agent's events", async ({
    page,
    browser,
  }) => {
    const suffix = uniqueSuffix();
    const workspace = { name: `Retenção ${suffix}`, slug: `retencao-${suffix}` };
    const user = { name: `Rita ${suffix}`, email: `rita-${suffix}@e2e.test` };
    const runnerName = `retencao-${suffix}`;

    // The operator: files kept 30 days, at most 1 MiB; events kept 30 days, then metadata.
    const backoffice = new BackofficePage(page);
    await backoffice.signInExpectingSuccess(bootstrapOperator.email, bootstrapOperator.password);
    await backoffice.createWorkspace(workspace.name);
    await backoffice.createMember(user.name, user.email, userPassword);
    await backoffice.setRetention(workspace.name, {
      filesDays: "30",
      quotaMib: "1",
      eventsDays: "30",
      eventsAfter: "metadata",
      shot: "backoffice-retention-form",
    });
    await backoffice.openWorkspace(workspace.slug);
    await expect(backoffice.filesUsage).toContainText("de 1 MiB");
    await expect(backoffice.retentionPolicy).toContainText("30 dias");
    await shot(page, "backoffice-workspace-retention");

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

    // A first task: its files fit in the quota.
    const tasks = new TasksPage(app.page);
    await tasks.open(workspace.slug);
    const firstId = await tasks.create({
      title: "Telas do login",
      prompt: "Tire as telas do login e gere o relatório. [arquivos]",
      pipeline: "Prompt único",
      project: "App",
    });

    await expect(tasks.status).toHaveText("Concluída", { timeout: 60_000 });
    await tasks.openStage("executar");
    await expect(tasks.stageRunFile("executar", 1, "dados/r.csv")).toBeVisible();
    const csvHref = await tasks
      .stageRunFileDownload("executar", 1, "dados/r.csv")
      .getAttribute("href");

    // The members see the files against the quota and the retention, read only.
    const usage = new UsagePage(app.page);
    await usage.open(workspace.slug);
    await expect(usage.filesBytes).toContainText("de 1 MiB");
    await expect(usage.retention).toContainText("30 dias");
    await expect(usage.retention).toContainText("metadados");
    await expect(usage.files).toBeVisible();
    await shot(app.page, "usage-files-retention");

    // The quota is full: a second task's files are refused, and it still ends well.
    inflateJobFile(workspace.slug, "dados/r.csv", 1_048_576);
    await tasks.open(workspace.slug);
    await tasks.create({
      title: "Telas de novo",
      prompt: "Tire as telas de novo. [arquivos]",
      pipeline: "Prompt único",
      project: "App",
    });

    await expect(tasks.status).toHaveText("Concluída", { timeout: 60_000 });
    await tasks.openStage("executar");
    const refused = tasks.stageRunFilesRefused("executar", 1);
    await expect(refused).toContainText("2 arquivos recusados");
    await expect(refused).toContainText("cota de anexos do workspace (1 MiB)");
    await expect(refused).not.toContainText("log do runner");
    await expect(tasks.stageRunFilesFailed("executar", 1)).toHaveCount(0);
    await expect(tasks.stageRunFile("executar", 1, "a.png")).toHaveCount(0);
    await shot(refused, "stage-run-files-refused");

    // Past the retention: the first task's files keep their names, without links.
    expireRetention(workspace.slug, 40);
    await tasks.show(workspace.slug, firstId);
    await tasks.openStage("executar");

    for (const path of ["a.png", "dados/r.csv"]) {
      await expect(tasks.stageRunFilePruned("executar", 1, path)).toContainText(path);
      await expect(tasks.stageRunFilePruned("executar", 1, path)).toContainText(
        "removido pela retenção",
      );
      await expect(tasks.stageRunFileDownload("executar", 1, path)).toHaveCount(0);
    }
    await expect(tasks.stageRunFileThumb("executar", 1, "a.png")).toHaveCount(0);
    await shot(tasks.stageRunFiles("executar", 1), "stage-run-files-pruned");

    const gone = await app.page.request.get(csvHref!);
    expect(gone.status()).toBe(410);

    // The steps stay, with only their metadata, under one notice.
    await tasks.openSteps("executar", 1);
    await expect(tasks.stageRunEventsPruned("executar", 1)).toContainText(
      "conteúdo removido pela retenção",
    );
    await expect(tasks.stageRunEventsPruned("executar", 1)).toHaveCount(1);
    await shot(app.page.getByTestId("stage-run-executar-1-panel-passos"), "stage-run-steps-pruned");

    await tasks.closeStage();
    await tasks.openNode("fim", "anexos");
    await expect(tasks.attachmentPruned("executar", 1, "a.png")).toContainText(
      "removido pela retenção",
    );
    await shot(app.page, "task-attachments-pruned");

    await context.close();
  });
});
