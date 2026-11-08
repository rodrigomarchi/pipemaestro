/**
 * @section Integrações
 * @flow F [done] An admin connects GitHub by installing the platform's App: saving sends them to GitHub, the installation comes back confirmed by their sign-in, and a repository of the installation is linked with the platform's labels and no webhook of its own
 */
import { expect, test } from "@playwright/test";
import { bootstrapOperator, uniqueSuffix, userPassword } from "../helpers/env";
import { createGitHubRepo, gitHubLabels } from "../helpers/fakeGitHub";
import { waitForLiveView } from "../helpers/liveView";
import { RunnerProcess } from "../helpers/runnerProcess";
import { shot } from "../helpers/screenshots";
import { AppPage } from "../pages/AppPage";
import { BackofficePage } from "../pages/BackofficePage";
import { IntegrationsPage, key } from "../pages/IntegrationsPage";
import { ProjectsPage } from "../pages/ProjectsPage";
import { RunnersPage } from "../pages/RunnersPage";
import { clickPageAction } from "../helpers/pageActions";

test.describe("GitHub App", () => {
  test.setTimeout(240_000);

  let runner: RunnerProcess;

  test.afterEach(() => runner?.cleanup());

  test("installs the App and links a repository", async ({ page, browser }) => {
    const suffix = uniqueSuffix();
    const workspace = { name: `GitHub ${suffix}`, slug: `github-${suffix}` };
    const admin = { name: `Gil ${suffix}`, email: `gil-${suffix}@e2e.test` };
    const repoName = `acme-${suffix}/app`;
    await createGitHubRepo(repoName);

    const backoffice = new BackofficePage(page);
    await backoffice.signInExpectingSuccess(bootstrapOperator.email, bootstrapOperator.password);
    await backoffice.createWorkspace(workspace.name);
    await backoffice.createMember(admin.name, admin.email, userPassword);

    const context = await browser.newContext();
    const app = new AppPage(await context.newPage());
    await app.signIn(admin.email, userPassword);
    await app.expectBoard(workspace.name);

    runner = new RunnerProcess();
    const root = runner.createCodeRoot();
    runner.start("runner.login", ["--url", app.page.url().replace(/\/w\/.*$/, "")]);
    const [, code] = await runner.waitFor(/digite o código:\s+([A-Z]{4}-[A-Z]{4})/);
    await new RunnersPage(app.page).approve(code, `github-${suffix}`);
    expect(await runner.waitForExit()).toBe(0);
    runner.start("runner.start", ["--root", root]);
    await runner.waitFor(/Online como/);

    const projects = new ProjectsPage(app.page);
    await projects.open(workspace.slug);
    await projects.create({ name: "App", runner: `github-${suffix}`, directory: "app" });

    const integrations = new IntegrationsPage(app.page);
    await integrations.open(workspace.slug);
    await clickPageAction(app.page, "integration-new");
    await waitForLiveView(app.page);
    await app.page.getByTestId("integration-provider").selectOption("github");
    await expect(app.page.getByTestId("integration-github-help")).toBeVisible();
    await app.page.getByTestId("integration-name").fill("GitHub da Acme");
    await shot(app.page, "github-form");
    await app.page.getByTestId("integration-save").click();

    // GitHub sends the person back with the installation, which the platform confirms.
    await expect(app.page.getByTestId("integration-bot")).toContainText("pipemaestro-e2e[bot]");
    await expect(app.page.getByTestId("integration-status")).toContainText("ativa");
    await waitForLiveView(app.page);

    await integrations.linkRepo(repoName, "App (app)");
    expect(await gitHubLabels(repoName)).toEqual(expect.arrayContaining(["pipemaestro", "pipemaestro:pronto"]));
    await app.page.getByTestId("repo-back").click();
    await expect(app.page.getByTestId(`repo-webhook-${key(repoName)}`)).toContainText("webhook do App");
    await shot(app.page, "github-connection");
  });
});
