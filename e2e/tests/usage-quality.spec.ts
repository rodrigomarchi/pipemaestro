/**
 * @section Uso
 * @flow Q [done] The quality tab of Usage: empty before any pull request; a task's PR that got a person's commit and was merged shows as accepted with changes, by pipeline, with the rework by stage, and follows the pipeline and project filters
 */
import { execFileSync } from "node:child_process";
import { writeFileSync } from "node:fs";
import { join } from "node:path";
import { expect, test } from "@playwright/test";
import { bootstrapOperator, uniqueSuffix, userPassword } from "../helpers/env";
import { createForgejoIssue, createForgejoRepo, fakeForgejo, forgejoState, pushForgejoPullCommit } from "../helpers/fakeForgejo";
import { waitForLiveView } from "../helpers/liveView";
import { RunnerProcess } from "../helpers/runnerProcess";
import { shot } from "../helpers/screenshots";
import { issueLabelPayload, pullRequestClosedPayload, sendForgejoWebhook } from "../helpers/webhook";
import { AppPage } from "../pages/AppPage";
import { BackofficePage } from "../pages/BackofficePage";
import { IntegrationsPage } from "../pages/IntegrationsPage";
import { PipelinesPage } from "../pages/PipelinesPage";
import { ProjectsPage } from "../pages/ProjectsPage";
import { RunnersPage } from "../pages/RunnersPage";
import { UsagePage } from "../pages/UsagePage";

test.describe("The quality of the deliveries", () => {
  test.setTimeout(300_000);

  let runner: RunnerProcess;

  test.afterEach(() => runner?.cleanup());

  test("a PR a person changed before the merge is accepted with changes", async ({ page, browser, request }) => {
    const suffix = uniqueSuffix();
    const workspace = { name: `Qualidade ${suffix}`, slug: `qualidade-${suffix}` };
    const admin = { name: `Bia ${suffix}`, email: `bia-${suffix}@e2e.test` };
    const repoName = `acme-${suffix}/app`;
    const issue = { number: 7, title: "Corrigir o rodapé", body: "O rodapé some no celular.", labels: ["pipemaestro"] };
    await createForgejoRepo(repoName);

    const backoffice = new BackofficePage(page);
    await backoffice.signInExpectingSuccess(bootstrapOperator.email, bootstrapOperator.password);
    await backoffice.createWorkspace(workspace.name);
    await backoffice.createMember(admin.name, admin.email, userPassword);

    const context = await browser.newContext();
    const app = new AppPage(await context.newPage());
    await app.signIn(admin.email, userPassword);
    await app.expectBoard(workspace.name);

    // No pull request delivered yet.
    const usage = new UsagePage(app.page);
    await usage.openTab(workspace.slug, "qualidade");
    await expect(usage.qualityEmpty).toBeVisible();
    await shot(app.page, "quality-empty");

    runner = new RunnerProcess();
    const root = runner.createCodeRoot();
    // The task's branch is pushed: `app` gets an origin of its own.
    const appDir = join(root, "app");
    const git = (...args: string[]) => execFileSync("git", ["-C", appDir, ...args], { stdio: "ignore" });
    const origin = join(root, "..", "origin.git");
    writeFileSync(join(appDir, ".gitignore"), "credencial-vista.txt\n");
    git("add", ".gitignore");
    git("-c", "user.email=e2e@e2e.test", "-c", "user.name=e2e", "commit", "-q", "-m", "gitignore");
    execFileSync("git", ["init", "-q", "--bare", "-b", "main", origin], { stdio: "ignore" });
    git("remote", "add", "origin", origin);
    git("push", "-q", "origin", "main");

    runner.start("runner.login", ["--url", app.page.url().replace(/\/w\/.*$/, "")]);
    const [, code] = await runner.waitFor(/digite o código:\s+([A-Z]{4}-[A-Z]{4})/);
    await new RunnersPage(app.page).approve(code, `qualidade-${suffix}`);
    expect(await runner.waitForExit()).toBe(0);
    runner.start("runner.start", ["--root", root]);
    await runner.waitFor(/Online como/);

    // The pipeline delivers in a PR, which a person merges.
    const pipelines = new PipelinesPage(app.page);
    await pipelines.open(workspace.slug);
    await pipelines.createDefaults();
    await pipelines.edit("Correção de bug");
    await pipelines.openEntry();
    await pipelines.openEntryTab("entrega");
    await app.page.getByTestId("pipeline-delivery").selectOption("pr");
    await pipelines.save();

    const projects = new ProjectsPage(app.page);
    await projects.open(workspace.slug);
    await projects.create({ name: "App", runner: `qualidade-${suffix}`, directory: "app" });

    const integrations = new IntegrationsPage(app.page);
    await integrations.open(workspace.slug);
    await integrations.createTokenConnection("Forgejo");
    const { url: webhookUrl, secret } = await integrations.webhook();
    await integrations.linkRepo(repoName, "App (app)");
    await app.page.getByTestId("trigger-new").click();
    await app.page.getByTestId("trigger-kind").selectOption("label");
    await app.page.getByTestId("trigger-label").fill("pipemaestro");
    await app.page.getByTestId("trigger-mode").selectOption("task");
    await app.page.getByTestId("trigger-pipeline").selectOption({ label: "Correção de bug" });
    await app.page.getByTestId("trigger-save").click();
    await expect(integrations.trigger({ kind: "label", label: "pipemaestro" })).toBeVisible();

    await createForgejoIssue({ repo: repoName, ...issue });
    const labeled = await sendForgejoWebhook(request, {
      url: webhookUrl,
      secret,
      event: "issue_label",
      id: `label-${suffix}`,
      payload: issueLabelPayload(repoName, issue, fakeForgejo.url),
    });
    expect(labeled.status()).toBe(202);

    const taskLink = async (): Promise<string | null> => {
      const state = await forgejoState(repoName);
      const found = state.comments.map((comment: { body: string }) => comment.body.match(/\/w\/[^/]+\/tasks\/[0-9a-f-]+/)).find(Boolean);
      return found ? found[0] : null;
    };
    await expect.poll(taskLink, { timeout: 60_000 }).not.toBeNull();
    await app.page.goto((await taskLink()) as string);
    await waitForLiveView(app.page);
    await expect(app.page.getByTestId("task-status")).toHaveText("Concluída", { timeout: 120_000 });
    await expect(app.page.getByTestId("task-overview-pr")).toHaveAttribute("href", /\/pulls\/1$/);

    // A person pushes a commit to the PR, then merges it.
    const [pull] = (await forgejoState(repoName)).pulls;
    await pushForgejoPullCommit(repoName, pull.number, `pessoa${suffix}`);
    const merged = await sendForgejoWebhook(request, {
      url: webhookUrl,
      secret,
      event: "pull_request",
      id: `merged-${suffix}`,
      payload: pullRequestClosedPayload(repoName, { number: pull.number, branch: pull.head.ref, merged: true }, fakeForgejo.url),
    });
    expect(merged.status()).toBe(202);

    // Usage tells it apart from a PR accepted as the pipeline left it.
    await expect(async () => {
      await usage.openTab(workspace.slug, "qualidade");
      await expect(usage.changed).toHaveText(/100%/, { timeout: 1_000 });
    }).toPass({ timeout: 30_000 });

    await expect(usage.delivered).toHaveText(/1/);
    await expect(usage.clean).toHaveText(/0%/);
    await expect(usage.closed).toHaveText(/0%/);
    await expect(usage.open).toHaveText(/0/);
    await expect(usage.mergeTime).toBeVisible();
    await expect(usage.reviewRounds).toHaveText(/0/);
    await expect(usage.pipelineRow("Correção de bug")).toContainText("100%");
    await expect(usage.stages).toBeVisible();
    await expect(usage.pauses).toBeVisible();
    await shot(app.page, "quality-accepted-with-changes");

    // The filters in the top bar narrow it.
    await usage.filterProject("App");
    await expect(usage.delivered).toHaveText(/1/);
    await usage.filterPipeline("Correção de bug");
    await expect(usage.pipelineRow("Correção de bug")).toContainText("100%");
    await expect(usage.changed).toHaveText(/100%/);
    await shot(app.page, "quality-filtered");
  });
});
