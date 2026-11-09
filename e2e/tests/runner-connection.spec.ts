/**
 * @section Runners
 * @flow A [done] A runner signs in with the device flow: the CLI prints a code, a workspace member approves it in the browser, the CLI saves its credentials
 * @flow B [done] The runner connects and shows online, live, on the runners page, the board and the backoffice, with its version, which is the runner's own and not the control plane's; the page links the deploy's runner binaries per platform and the connect steps use them, naming the runner's version the platform requires
 * @flow E [done] A runner not on the runner's version the platform requires is refused, on login and on start; with --no-auto-update (updating is the default) it is asked whether to download and install that version, and, answering no, told which runner's version the platform asks for and where to download it
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
import { ProjectsPage } from "../pages/ProjectsPage";
import { RunnersPage } from "../pages/RunnersPage";

const escapeRegExp = (text: string) => text.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");

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

    const platform = app.page.url().replace(/\/w\/.*$/, "");
    const updateQuestion = new RegExp(
      `Baixar e instalar a versão ${escapeRegExp(versions.runner)} agora\\? \\[S/n\\]`,
    );

    // Flow E: an outdated runner cannot even sign in. Updating is the default:
    // --no-auto-update makes it ask instead.
    runner = new RunnerProcess({ version: versions.outdatedRunner });
    const root = runner.createCodeRoot();
    runner.start("runner.login", ["--url", platform, "--no-auto-update"]);
    await runner.waitFor(updateQuestion);
    runner.write("n\n");
    expect(await runner.waitForExit()).not.toBe(0);
    expect(runner.text).toContain(
      `versão ${versions.outdatedRunner}, e a plataforma pede a versão ${versions.runner} do runner`,
    );
    expect(runner.text).toContain(`${platform}/downloads/runner/`);

    // Flow A: device-flow sign-in, on the runner's version the platform requires.
    runner.useVersion(versions.runner);
    runner.start("runner.login", ["--url", platform, "--label", "e2e"]);
    const [, code] = await runner.waitFor(/digite o código:\s+([A-Z]{4}-[A-Z]{4})/);

    await runners.approve(code, runnerName);
    await shot(app.page, "runner-approved");
    await runner.waitFor(new RegExp(`Runner "${runnerName}" conectado ao workspace ${workspace.name}`));
    expect(await runner.waitForExit()).toBe(0);

    await runners.open(workspace.slug);
    await expect(runners.status(runnerName)).toHaveText("Offline");

    // Flow E: signed in, but started on an older build, it is refused and stops.
    runner.useVersion(versions.outdatedRunner);
    runner.start("runner.start", ["--no-auto-update"]);
    await runner.waitFor(updateQuestion);
    runner.write("n\n");
    expect(await runner.waitForExit()).not.toBe(0);
    expect(runner.text).toContain(`a plataforma pede a versão ${versions.runner} do runner`);
    await expect(runners.status(runnerName)).toHaveText("Offline");

    // Flow B: connect and show online live.
    runner.useVersion(versions.runner);
    runner.start("runner.start", ["--root", root]);
    await runner.waitFor(/Online como/);
    // Mix may print what it compiled first; the command's first line is its version.
    expect(runner.text).toContain(`pipemaestro ${versions.runner}\nWorkdir:`);
    await expect(runners.status(runnerName)).toHaveText("Online");
    await expect(app.page.getByTestId(`runner-labels-${runnerName}`)).toContainText("e2e");
    await expect(runners.version(runnerName)).toHaveText(versions.runner);
    await expect(runners.outdated(runnerName)).toHaveCount(0);
    // The footer keeps the control plane's own version.
    await expect(app.page.getByTestId("app-version")).toHaveText(versions.controlPlane);
    await shot(app.page, "runner-online");

    // The deploy's runner binaries, one link per platform, and the connect steps that use them.
    for (const target of ["macos_arm64", "macos_x86_64", "linux_x86_64", "linux_arm64"]) {
      await expect(runners.download(target)).toHaveAttribute("href", `/downloads/runner/pipemaestro_${target}`);
    }
    await runners.download("macos_arm64").scrollIntoViewIfNeeded();
    await shot(app.page, "runner-downloads");
    await expect(await runners.openConnect()).toHaveText(/^pipemaestro login --url http/);
    await expect(runners.expectedVersion).toContainText(versions.runner);
    await shot(app.page, "runner-connect-downloads");
    await app.page.keyboard.press("Escape");

    await backoffice.openWorkspace(workspace.slug);
    await expect(page.getByTestId(`workspace-runner-status-${runnerName}`)).toHaveText("Online");
    await shot(page, "backoffice-runner-online");

    // Flow D: the runner's page lists the jobs it finished.
    await runners.openRunner(workspace.slug, runnerName);
    await expect(runners.noRecentJobs).toBeVisible();
    await expect(runners.detailVersion).toHaveText(versions.runner);
    await expect(runners.detailOutdated).toHaveCount(0);
    await shot(app.page, "runner-detail-no-recent-jobs");

    const projects = new ProjectsPage(app.page);
    await projects.open(workspace.slug);
    await projects.create({ name: "App", runner: runnerName, directory: "app" });

    const jobs = new JobsPage(app.page);
    await jobs.open(workspace.slug);
    const prompt = `Liste os arquivos do projeto (${suffix})`;
    const jobId = await jobs.create("App", prompt);
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
    await new JobsPage(app.page).openNode("agente", "auditoria");
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
