/**
 * @section Runners
 * @flow A [done] The runner page's "Conexões" tab shows each connection: the one live, a stop that ended it, a join refused for its version; the list shows the runner's uptime over the week
 * @flow B [done] The "Saúde" tab shows the machine's CPU, memory, load and free disk as the runner reports them, and the week's jobs; the list shows the runner's failures over the week
 */
import { expect, test } from "@playwright/test";
import { bootstrapOperator, uniqueSuffix, userPassword, versions } from "../helpers/env";
import { RunnerProcess } from "../helpers/runnerProcess";
import { shot } from "../helpers/screenshots";
import { AppPage } from "../pages/AppPage";
import { BackofficePage } from "../pages/BackofficePage";
import { RunnersPage } from "../pages/RunnersPage";

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
    await shot(app.page, "runners-list-telemetry");

    await context.close();
  });
});
