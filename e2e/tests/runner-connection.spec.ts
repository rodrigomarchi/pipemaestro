/**
 * @section Runners
 * @flow A [done] A runner signs in with the device flow: the CLI prints a code, a workspace member approves it in the browser, the CLI saves its credentials
 * @flow B [done] The runner connects and shows online, live, on the runners page, the board and the backoffice, with its version, marked outdated when older than the control plane's
 * @flow D [done] A runner's page lists the latest jobs it finished, each leading to its audit
 * @flow C [done] A member renames the runner, then revokes it: the CLI is refused and stops, and the runner leaves the list
 */
import { expect, test } from "@playwright/test";
import { bootstrapOperator, uniqueSuffix, userPassword, versions } from "../helpers/env";
import { RunnerProcess } from "../helpers/runnerProcess";
import { shot } from "../helpers/screenshots";
import { AppPage } from "../pages/AppPage";
import { BackofficePage } from "../pages/BackofficePage";
import { JobsPage } from "../pages/JobsPage";
import { RunnersPage } from "../pages/RunnersPage";

test.describe("Runner connection", () => {
  // Real CLI processes: the first one may compile the runner app.
  test.setTimeout(240_000);

  let runner: RunnerProcess;

  test.afterEach(() => runner?.cleanup());

  test("signs in, connects, is renamed and revoked", async ({ page, browser }) => {
    const suffix = uniqueSuffix();
    const workspace = { name: `Runners ${suffix}`, slug: `runners-${suffix}` };
    const user = { name: `Rita ${suffix}`, email: `rita-${suffix}@e2e.test` };
    const runnerName = `e2e-${suffix}`;
    const renamed = `build-${suffix}`;

    const backoffice = new BackofficePage(page);
    await backoffice.signInExpectingSuccess(bootstrapOperator.email, bootstrapOperator.password);
    await backoffice.createWorkspace(workspace.name);
    await backoffice.createMember(user.name, user.email, userPassword);

    const context = await browser.newContext();
    const app = new AppPage(await context.newPage());
    await app.signIn(user.email, userPassword);
    await app.expectBoard(workspace.name);
    const runners = new RunnersPage(app.page);

    // Flow A: device-flow sign-in.
    runner = new RunnerProcess({ version: versions.outdatedRunner });
    runner.start("runner.login", ["--url", app.page.url().replace(/\/w\/.*$/, ""), "--label", "e2e"]);
    const [, code] = await runner.waitFor(/digite o código:\s+([A-Z]{4}-[A-Z]{4})/);

    await runners.approve(code, runnerName);
    await shot(app.page, "runner-approved");
    await runner.waitFor(new RegExp(`Runner "${runnerName}" conectado ao workspace ${workspace.name}`));
    expect(await runner.waitForExit()).toBe(0);

    await runners.open(workspace.slug);
    await expect(runners.status(runnerName)).toHaveText("Offline");

    // Flow B: connect and show online live.
    runner.start("runner.start");
    await runner.waitFor(/Online como/);
    // Mix may print what it compiled first; the command's first line is its version.
    expect(runner.text).toContain(`cp-runner ${versions.outdatedRunner}\nWorkdir:`);
    await expect(runners.status(runnerName)).toHaveText("Online");
    await expect(app.page.getByTestId(`runner-labels-${runnerName}`)).toContainText("e2e");
    await expect(runners.version(runnerName)).toHaveText(versions.outdatedRunner);
    await expect(runners.outdated(runnerName)).toHaveText("desatualizado");
    await expect(app.page.getByTestId("app-version")).toHaveText(versions.controlPlane);
    await shot(app.page, "runner-online");

    await backoffice.openWorkspace(workspace.slug);
    await expect(page.getByTestId(`workspace-runner-status-${runnerName}`)).toHaveText("Online");
    await shot(page, "backoffice-runner-online");

    // Flow D: the runner's page lists the jobs it finished.
    await runners.openRunner(workspace.slug, runnerName);
    await expect(runners.noRecentJobs).toBeVisible();
    await expect(runners.detailVersion).toHaveText(versions.outdatedRunner);
    await expect(runners.detailOutdated).toHaveText("desatualizado");
    await shot(app.page, "runner-detail-no-recent-jobs");

    const jobs = new JobsPage(app.page);
    await jobs.open(workspace.slug);
    const prompt = `Liste os arquivos do workdir (${suffix})`;
    const jobId = await jobs.create(runnerName, prompt);
    await expect(jobs.status).toHaveText("Concluído");

    await runners.openRunner(workspace.slug, runnerName);
    await expect(runners.recentJob(jobId, "status")).toHaveText("Concluído");
    await expect(runners.recentJob(jobId, "link")).toHaveText(prompt);
    await expect(runners.recentJob(jobId, "duration")).toHaveText("1 s");
    await expect(runners.recentJob(jobId, "cost")).toHaveText("US$ 0.0042");
    await expect(runners.recentJob(jobId, "cache")).toHaveText("91%");
    await expect(runners.noRecentJobs).toHaveCount(0);
    await shot(app.page, "runner-recent-jobs");

    await runners.recentJob(jobId, "link").click();
    await expect(app.page.getByTestId("job-audit")).toBeVisible();

    // Flow C: rename, then revoke.
    await runners.open(workspace.slug);
    await runners.rename(runnerName, renamed);
    await expect(runners.status(renamed)).toHaveText("Online");

    await runners.revoke(renamed);
    await expect(runners.runner(renamed)).toHaveCount(0);
    await runner.waitFor(/A plataforma recusou este runner/);
    expect(await runner.waitForExit()).not.toBe(0);
    await shot(app.page, "runner-revoked");

    await context.close();
  });
});
