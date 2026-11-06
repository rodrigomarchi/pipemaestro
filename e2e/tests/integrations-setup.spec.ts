/**
 * @section Integrações
 * @flow A [done] An admin connects a Forgejo with a bot's token, links a repository to a project (the platform creates its labels and webhook) and adds a label trigger
 * @flow B [done] An admin connects a Forgejo by OAuth: saving sends them to authorize and they come back with the connection active
 */
import { expect, test } from "@playwright/test";
import { bootstrapOperator, uniqueSuffix, userPassword } from "../helpers/env";
import { createForgejoRepo, forgejoState } from "../helpers/fakeForgejo";
import { RunnerProcess } from "../helpers/runnerProcess";
import { shot } from "../helpers/screenshots";
import { AppPage } from "../pages/AppPage";
import { BackofficePage } from "../pages/BackofficePage";
import { IntegrationsPage, key } from "../pages/IntegrationsPage";
import { PipelinesPage } from "../pages/PipelinesPage";
import { ProjectsPage } from "../pages/ProjectsPage";
import { RunnersPage } from "../pages/RunnersPage";

test.describe("Integrations setup", () => {
  test.setTimeout(240_000);

  let runner: RunnerProcess;

  test.afterEach(() => runner?.cleanup());

  test("connects a Forgejo, links a repository and adds triggers", async ({ page, browser }) => {
    const suffix = uniqueSuffix();
    const workspace = { name: `Integra ${suffix}`, slug: `integra-${suffix}` };
    const admin = { name: `Iara ${suffix}`, email: `iara-${suffix}@e2e.test` };
    const repoName = `acme-${suffix}/app`;
    await createForgejoRepo(repoName);

    const backoffice = new BackofficePage(page);
    await backoffice.signInExpectingSuccess(bootstrapOperator.email, bootstrapOperator.password);
    await backoffice.createWorkspace(workspace.name);
    await backoffice.createMember(admin.name, admin.email, userPassword);

    const context = await browser.newContext();
    const app = new AppPage(await context.newPage());
    await app.signIn(admin.email, userPassword);
    await app.expectBoard(workspace.name);

    // A project needs a directory a runner offers.
    runner = new RunnerProcess();
    const root = runner.createCodeRoot();
    runner.start("runner.login", ["--url", app.page.url().replace(/\/w\/.*$/, "")]);
    const [, code] = await runner.waitFor(/digite o código:\s+([A-Z]{4}-[A-Z]{4})/);
    await new RunnersPage(app.page).approve(code, `integra-${suffix}`);
    expect(await runner.waitForExit()).toBe(0);
    runner.start("runner.start", ["--root", root]);
    await runner.waitFor(/Online como/);

    const pipelines = new PipelinesPage(app.page);
    await pipelines.open(workspace.slug);
    await pipelines.createDefaults();
    const projects = new ProjectsPage(app.page);
    await projects.open(workspace.slug);
    await projects.create({ name: "App", directory: "app" });

    const integrations = new IntegrationsPage(app.page);
    await integrations.open(workspace.slug);
    await expect(app.page.getByTestId("no-integrations")).toBeVisible();
    await shot(app.page, "integrations-empty");

    await integrations.createTokenConnection("Forgejo da casa", { shot: "connection-form" });
    await expect(app.page.getByTestId("integration-status")).toContainText("ativa");
    await expect(app.page.getByTestId("integration-webhook-url")).toContainText("/api/integrations/");
    await shot(app.page, "connection");

    await integrations.linkRepo(repoName, "App (app)", { shot: "repo-link" });
    const state = await forgejoState(repoName);
    expect(state.hooks).toHaveLength(1);
    expect(state.hooks[0].config.url).toContain("/api/integrations/");
    expect(state.labels.map((label: { name: string }) => label.name)).toEqual(
      expect.arrayContaining(["pipemaestro", "pipemaestro:em-andamento", "pipemaestro:pronto"]),
    );

    await integrations.addTrigger({ kind: "label", label: "pipemaestro" }, { shot: "trigger-form" });
    await integrations.addTrigger({ kind: "comment", command: "/pipemaestro", pipeline: "Correção de bug" });
    await expect(integrations.trigger({ kind: "comment", command: "/pipemaestro" })).toContainText("Correção de bug");
    await shot(app.page, "repo-triggers");

    await app.page.getByTestId("repo-back").click();
    await expect(app.page.getByTestId(`repo-webhook-${key(repoName)}`)).toContainText("webhook criado");
    await integrations.open(workspace.slug);
    await expect(app.page.getByTestId("integration-status-forgejo-da-casa")).toContainText("ativa");
    await shot(app.page, "integrations");

    await integrations.createOAuthConnection("Forgejo por OAuth");
    await expect(app.page.getByTestId("integration-status")).toContainText("ativa");
    await shot(app.page, "oauth-connection");
  });
});
