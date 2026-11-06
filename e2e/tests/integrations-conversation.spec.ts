/**
 * @section Integrações
 * @flow E [done] A task from a Forgejo issue stops for a decision; a writer comments "/pipemaestro seguir" on the issue and the task goes on, the comment getting a 👍
 */
import { expect, test } from "@playwright/test";
import { bootstrapOperator, uniqueSuffix, userPassword } from "../helpers/env";
import { createForgejoIssue, createForgejoRepo, fakeForgejo, forgejoState } from "../helpers/fakeForgejo";
import { waitForLiveView } from "../helpers/liveView";
import { RunnerProcess } from "../helpers/runnerProcess";
import { shot } from "../helpers/screenshots";
import { issueCommentPayload, issueLabelPayload, sendForgejoWebhook } from "../helpers/webhook";
import { AppPage } from "../pages/AppPage";
import { BackofficePage } from "../pages/BackofficePage";
import { IntegrationsPage, key } from "../pages/IntegrationsPage";
import { PipelinesPage } from "../pages/PipelinesPage";
import { ProjectsPage } from "../pages/ProjectsPage";
import { RunnersPage } from "../pages/RunnersPage";

test.describe("Conversation on the issue", () => {
  test.setTimeout(300_000);

  let runner: RunnerProcess;

  test.afterEach(() => runner?.cleanup());

  test("a command in a comment decides a task waiting for a decision", async ({ page, browser, request }) => {
    const suffix = uniqueSuffix();
    const workspace = { name: `Conversa ${suffix}`, slug: `conversa-${suffix}` };
    const admin = { name: `Caio ${suffix}`, email: `caio-${suffix}@e2e.test` };
    const repoName = `acme-${suffix}/app`;
    // "[bloqueio]" makes the fake agent stop the stage for a decision.
    const issue = { number: 5, title: "Trocar o banco [bloqueio]", body: "Falta decidir o banco. [bloqueio]", labels: ["pipemaestro"] };
    await createForgejoRepo(repoName);

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
    await new RunnersPage(app.page).approve(code, `conversa-${suffix}`);
    expect(await runner.waitForExit()).toBe(0);
    runner.start("runner.start", ["--root", root]);
    await runner.waitFor(/Online como/);

    const pipelines = new PipelinesPage(app.page);
    await pipelines.open(workspace.slug);
    await pipelines.createDefaults();
    const projects = new ProjectsPage(app.page);
    await projects.open(workspace.slug);
    await projects.create({ name: "App", runner: `conversa-${suffix}`, directory: "app" });

    const integrations = new IntegrationsPage(app.page);
    await integrations.open(workspace.slug);
    await integrations.createTokenConnection("Forgejo");
    const webhookUrl = (await app.page.getByTestId("integration-webhook-url").innerText()).trim();
    await app.page.getByTestId("integration-webhook-secret-reveal").click();
    await expect(app.page.getByTestId("integration-webhook-secret")).not.toContainText("•");
    const secret = (await app.page.getByTestId("integration-webhook-secret").innerText()).trim();
    const connectionPage = app.page.url();

    await integrations.linkRepo(repoName, "App (app)");
    // Straight to the task, so its first stage is the one that stops.
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

    // The issue says the task waits for a decision.
    await expect
      .poll(async () => {
        const state = await forgejoState(repoName);
        return state.issues.find((candidate: { number: number }) => candidate.number === 5).labels.map((label: { name: string }) => label.name);
      }, { timeout: 120_000 })
      .toContain("pipemaestro:aguardando-decisao");

    // A writer decides on the issue.
    const commented = await sendForgejoWebhook(request, {
      url: webhookUrl,
      secret,
      event: "issue_comment",
      id: `comment-${suffix}`,
      payload: issueCommentPayload(repoName, issue, { id: 4242, body: "/pipemaestro seguir siga sem o banco novo", author: "ana" }, fakeForgejo.url),
    });
    expect(commented.status()).toBe(202);

    await expect
      .poll(async () => (await forgejoState(repoName)).reactions, { timeout: 30_000 })
      .toContainEqual({ target: "comment", id: 4242, content: "+1" });

    await app.page.goto(connectionPage);
    await waitForLiveView(app.page);
    await expect(app.page.getByTestId(`delivery-status-${key(`comment-${suffix}`)}`)).toContainText("processada");
    await expect(app.page.getByTestId(`delivery-${key(`comment-${suffix}`)}`)).toContainText("comando seguir aplicado por ana");
    await shot(app.page, "command-applied");
  });
});
