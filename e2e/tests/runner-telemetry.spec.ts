/**
 * @section Runners
 * @flow A [done] The runner page's "Conexões" tab shows each connection: the one live, a stop that ended it, a join refused for its version; the list shows the runner's uptime over the week
 * @flow C [done] The "Eventos e logs" tab shows the runner's own log, live, and an event for a task's setup that failed, filtered by group
 * @flow D [done] The "Diagnóstico" tab shows the doctor the runner ran as it connected, and a member runs it again from the page
 * @flow E [done] A runner whose agent CLI is missing is degraded: its diagnosis is in error, the list marks it and the board alerts on it
 * @flow B [done] The "Saúde" tab shows the machine's CPU, memory, load and free disk as the runner reports them, and the week's jobs; the list shows the runner's failures over the week
 */
import { expect, test } from "@playwright/test";
import { bootstrapOperator, uniqueSuffix, userPassword, versions } from "../helpers/env";
import { RunnerProcess } from "../helpers/runnerProcess";
import { shot } from "../helpers/screenshots";
import { AppPage } from "../pages/AppPage";
import { BackofficePage } from "../pages/BackofficePage";
import { PipelinesPage } from "../pages/PipelinesPage";
import { ProjectsPage } from "../pages/ProjectsPage";
import { RunnersPage } from "../pages/RunnersPage";
import { TasksPage } from "../pages/TasksPage";

test.describe("Runner telemetry", () => {
  // Real CLI processes: the first one may compile the runner app.
  test.setTimeout(240_000);

  let runner: RunnerProcess;

  test.afterEach(() => runner?.cleanup());

  test("the runner's connections, health, log and diagnosis", async ({ page, browser }) => {
    const suffix = uniqueSuffix();
    const workspace = { name: `Telemetria ${suffix}`, slug: `telemetria-${suffix}` };
    const user = { name: `Tina ${suffix}`, email: `tina-${suffix}@e2e.test` };
    const runnerName = `tele-${suffix}`;

    const backoffice = new BackofficePage(page);
    await backoffice.signInExpectingSuccess(bootstrapOperator.email, bootstrapOperator.password);
    await backoffice.createWorkspace(workspace.name);
    await backoffice.createMember(user.name, user.email, userPassword);

    const context = await browser.newContext();
    const app = new AppPage(await context.newPage());
    await app.signIn(user.email, userPassword);
    await app.expectBoard(workspace.name);
    const runners = new RunnersPage(app.page);

    // A health sample every 2 s instead of every minute.
    runner = new RunnerProcess({ env: { RUNNER_HEALTH_EVERY_MS: "2000" } });
    const root = runner.createCodeRoot();
    runner.start("runner.login", ["--url", app.page.url().replace(/\/w\/.*$/, "")]);
    const [, code] = await runner.waitFor(/digite o código:\s+([A-Z]{4}-[A-Z]{4})/);
    await runners.approve(code, runnerName);
    expect(await runner.waitForExit()).toBe(0);

    // Flow A: a connection that a stop ends, a join refused for its version, one live.
    runner.start("runner.start", ["--root", root]);
    await runner.waitFor(/Online como/);
    await runners.open(workspace.slug);
    await expect(runners.status(runnerName)).toHaveText("Online");
    runner.stop();
    await runner.waitForExit();
    await expect(runners.status(runnerName)).toHaveText("Offline");

    runner.useVersion(versions.outdatedRunner);
    runner.start("runner.start", ["--no-auto-update"]);
    await runner.waitFor(/\[S\/n\]/);
    runner.write("n\n");
    expect(await runner.waitForExit()).not.toBe(0);

    runner.useVersion(versions.runner);
    runner.start("runner.start", ["--root", root]);
    await runner.waitFor(/Online como/);
    await expect(runners.status(runnerName)).toHaveText("Online");
    await expect(runners.uptime(runnerName)).toContainText("uptime 7d");

    await runners.openRunner(workspace.slug, runnerName);
    await runners.openTab("conexoes");
    await expect(runners.connections).toBeVisible();
    await expect(runners.sessionReasons).toHaveText(["conectado", "recusado: versão", "conexão encerrada"]);
    await expect(runners.dropsDay).toHaveText("1");
    await expect(runners.uptimeDay).toContainText("%");
    await shot(app.page, "runner-connections");

    // Flow B: the machine's health, as the runner reports it.
    await runners.openTab("saude");
    await expect(runners.health).toBeVisible();
    await expect(runners.healthValue("cpu")).toHaveText(/^\s*\d+%\s*$/);
    await expect(runners.healthValue("memory")).toContainText(" de ");
    await expect(runners.healthValue("disk")).toContainText("%");
    await expect(runners.runStat("runs")).toHaveText("0");
    await shot(app.page, "runner-health");

    await runners.open(workspace.slug);
    await expect(runners.failures(runnerName)).toHaveText("falhas 7d —");

    // Flow C: a task whose setup fails, then the runner's events and log.
    const projects = new ProjectsPage(app.page);
    await projects.open(workspace.slug);
    await projects.create({ name: "App", runner: runnerName, directory: "app", setup: "echo quebrou && exit 3" });
    const pipelines = new PipelinesPage(app.page);
    await pipelines.open(workspace.slug);
    await pipelines.createDefaults();
    const tasks = new TasksPage(app.page);
    await tasks.open(workspace.slug);
    await tasks.create({ title: "Setup quebrado", prompt: "Faça algo.", pipeline: "Prompt único", project: "App" });
    await expect(tasks.status).toHaveText("Aguardando decisão", { timeout: 60_000 });

    await runners.open(workspace.slug);
    await expect(runners.failures(runnerName)).not.toHaveText("falhas 7d —");
    await shot(app.page, "runners-list-telemetry");

    await runners.openRunner(workspace.slug, runnerName);
    await runners.openTab("eventos");
    await expect(runners.event("setup_failed").first()).toContainText("O setup do worktree falhou");
    await expect(runners.logLines.filter({ hasText: "Online como" }).first()).toBeVisible();
    await shot(app.page, "runner-events-log");

    await runners.filterEvents("connection");
    await expect(runners.event("setup_failed")).toHaveCount(0);

    // Flow D: the diagnosis the runner ran as it connected, and one more on request.
    await runners.openTab("diagnostico");
    await expect(runners.doctorCheck("git")).toBeVisible({ timeout: 30_000 });
    await expect(runners.doctorCheck("platform")).toContainText("responde");
    await expect(runners.runDoctor).toHaveText(/Rodar agora/);
    await runners.runDoctor.click();
    await expect(runners.runDoctor).toHaveText(/Rodando/);
    await expect(runners.runDoctor).toHaveText(/Rodar agora/, { timeout: 30_000 });
    await shot(app.page, "runner-doctor");

    // Flow E: started without its agent CLI, the runner's diagnosis fails.
    runner.stop();
    await runner.waitForExit();
    runner.useClaudeBin("/nonexistent/claude");
    runner.start("runner.start", ["--root", root]);
    await runner.waitFor(/Online como/);

    await app.openBoard(workspace.slug);
    await expect(app.degradedAlert(runnerName)).toContainText("diagnóstico com erro", { timeout: 30_000 });
    await shot(app.page, "board-runner-degraded");

    await runners.open(workspace.slug);
    await expect(runners.degraded(runnerName)).toBeVisible();

    await context.close();
  });
});
