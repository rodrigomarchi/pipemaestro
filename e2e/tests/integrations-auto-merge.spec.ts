/**
 * @section Integrações
 * @flow G [done] A pipeline set to merge its pull request takes a Forgejo issue to a merged PR: the task ends, waits for the repository's CI, and the platform merges once it passes
 */
import { execFileSync } from "node:child_process";
import { writeFileSync } from "node:fs";
import { join } from "node:path";
import { expect, test } from "@playwright/test";
import { bootstrapOperator, uniqueSuffix, userPassword } from "../helpers/env";
import { createForgejoIssue, createForgejoRepo, fakeForgejo, forgejoState, setForgejoCi } from "../helpers/fakeForgejo";
import { waitForLiveView } from "../helpers/liveView";
import { RunnerProcess } from "../helpers/runnerProcess";
import { shot } from "../helpers/screenshots";
import { issueLabelPayload, sendForgejoWebhook } from "../helpers/webhook";
import { AppPage } from "../pages/AppPage";
import { BackofficePage } from "../pages/BackofficePage";
import { IntegrationsPage } from "../pages/IntegrationsPage";
import { PipelinesPage } from "../pages/PipelinesPage";
import { ProjectsPage } from "../pages/ProjectsPage";
import { RunnersPage } from "../pages/RunnersPage";

test.describe("Merging the pull request", () => {
  test.setTimeout(300_000);

  let runner: RunnerProcess;

  test.afterEach(() => runner?.cleanup());

  test("the platform merges the task's PR once the repository's CI passes", async ({ page, browser, request }) => {
    const suffix = uniqueSuffix();
    const workspace = { name: `Merge ${suffix}`, slug: `merge-${suffix}` };
    const admin = { name: `Bia ${suffix}`, email: `bia-${suffix}@e2e.test` };
    const repoName = `acme-${suffix}/app`;
    const issue = { number: 7, title: "Corrigir o rodapé", body: "O rodapé some no celular.", labels: ["pipemaestro"] };
    await createForgejoRepo(repoName);
    // The repository's CI reports on every commit, and is still running.
    await setForgejoCi(repoName, "pending");

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
    // The task's branch is pushed: `app` gets an origin of its own. With the
    // job's git credential the fake agent writes down what git read for the
    // host, which is no work of the task.
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
    await new RunnersPage(app.page).approve(code, `merge-${suffix}`);
    expect(await runner.waitForExit()).toBe(0);
    runner.start("runner.start", ["--root", root]);
    await runner.waitFor(/Online como/);

    // The pipeline delivers in a PR and merges it.
    const pipelines = new PipelinesPage(app.page);
    await pipelines.open(workspace.slug);
    await pipelines.createDefaults();
    await pipelines.edit("Correção de bug");
    await pipelines.openEntry();
    await pipelines.openEntryTab("entrega");
    await app.page.getByTestId("pipeline-delivery").selectOption("pr");
    const autoMerge = app.page.getByTestId("pipeline-auto-merge");
    await expect(autoMerge).not.toBeChecked();
    // Petal's switch hides its input (sr-only): the keyboard toggles it.
    await autoMerge.focus();
    await app.page.keyboard.press("Space");
    await expect(autoMerge).toBeChecked();
    await app.page.getByTestId("pipeline-merge-method").selectOption("squash");
    await app.page.getByTestId("pipeline-max-merge-fixes").fill("2");
    await expect(app.page.getByTestId("pipeline-auto-merge-help")).toContainText("integração");
    await shot(app.page.getByTestId("pipeline-auto-merge-section"), "pipeline-auto-merge");
    await pipelines.save();

    const projects = new ProjectsPage(app.page);
    await projects.open(workspace.slug);
    await projects.create({ name: "App", runner: `merge-${suffix}`, directory: "app" });

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

    // The issue's status comment leads to the task.
    const taskLink = async (): Promise<string | null> => {
      const state = await forgejoState(repoName);
      const found = state.comments.map((comment: { body: string }) => comment.body.match(/\/w\/[^/]+\/tasks\/[0-9a-f-]+/)).find(Boolean);
      return found ? found[0] : null;
    };
    await expect.poll(taskLink, { timeout: 60_000 }).not.toBeNull();
    const taskPath = (await taskLink()) as string;

    await app.page.goto(taskPath);
    await waitForLiveView(app.page);

    // Every stage done, the PR waits for the CI.
    await expect(app.page.getByTestId("task-status")).toHaveText("Concluída", { timeout: 120_000 });
    await expect(app.page.getByTestId("task-merge-state")).toHaveText("Merge: aguardando checks", { timeout: 30_000 });
    await expect(app.page.getByTestId("task-overview-pr")).toHaveAttribute("href", /\/pulls\/1$/);
    await shot(app.page, "task-waiting-checks");
    expect((await forgejoState(repoName)).pulls[0].merged).toBeFalsy();

    // The CI passes: the platform merges.
    await setForgejoCi(repoName, "success");
    await expect(app.page.getByTestId("task-merge-state")).toHaveText("Integrado", { timeout: 30_000 });
    await shot(app.page, "task-merged");

    const [pull] = (await forgejoState(repoName)).pulls;
    expect(pull.merged).toBe(true);
    expect(pull.merge.Do).toBe("squash");
  });
});
