/**
 * @section Integrações
 * @flow C [done] A label added to a Forgejo issue reaches the platform by webhook: the delivery is recorded, the agent triages the issue and the task is created on its own, linked to the issue, which gets a reaction and the triage label; the same delivery again is a duplicate
 * @flow D [done] While the task runs, the issue shows it: one status comment edited in place and the state label, up to "pronto" when the task ends
 */
import { expect, test } from "@playwright/test";
import { bootstrapOperator, uniqueSuffix, userPassword } from "../helpers/env";
import { createForgejoIssue, createForgejoRepo, fakeForgejo, forgejoState } from "../helpers/fakeForgejo";
import { waitForLiveView } from "../helpers/liveView";
import { RunnerProcess } from "../helpers/runnerProcess";
import { shot } from "../helpers/screenshots";
import { issueLabelPayload, sendForgejoWebhook } from "../helpers/webhook";
import { AppPage } from "../pages/AppPage";
import { BackofficePage } from "../pages/BackofficePage";
import { IntegrationsPage, key } from "../pages/IntegrationsPage";
import { PipelinesPage } from "../pages/PipelinesPage";
import { ProjectsPage } from "../pages/ProjectsPage";
import { ProposalPage } from "../pages/ProposalPage";
import { RunnersPage } from "../pages/RunnersPage";

test.describe("Issue to task", () => {
  test.setTimeout(300_000);

  let runner: RunnerProcess;

  test.afterEach(() => runner?.cleanup());

  test("a labeled Forgejo issue becomes a task written by the agent", async ({ page, browser, request }) => {
    const suffix = uniqueSuffix();
    const workspace = { name: `Issues ${suffix}`, slug: `issues-${suffix}` };
    const admin = { name: `Ivo ${suffix}`, email: `ivo-${suffix}@e2e.test` };
    const repoName = `acme-${suffix}/app`;
    const issue = { number: 3, title: "O login quebra com e-mail maiúsculo", body: "Entrar com ANA@X.COM falha.", labels: ["bug", "pipemaestro"] };
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
    await new RunnersPage(app.page).approve(code, `issues-${suffix}`);
    expect(await runner.waitForExit()).toBe(0);
    runner.start("runner.start", ["--root", root]);
    await runner.waitFor(/Online como/);

    const pipelines = new PipelinesPage(app.page);
    await pipelines.open(workspace.slug);
    await pipelines.createDefaults();
    const projects = new ProjectsPage(app.page);
    await projects.open(workspace.slug);
    await projects.create({ name: "App", runner: `issues-${suffix}`, directory: "app" });

    const integrations = new IntegrationsPage(app.page);
    await integrations.open(workspace.slug);
    await integrations.createTokenConnection("Forgejo");
    const webhookUrl = (await app.page.getByTestId("integration-webhook-url").innerText()).trim();
    await app.page.getByTestId("integration-webhook-secret-reveal").click();
    await expect(app.page.getByTestId("integration-webhook-secret")).not.toContainText("•");
    const secret = (await app.page.getByTestId("integration-webhook-secret").innerText()).trim();
    const connectionPage = app.page.url();

    await integrations.linkRepo(repoName, "App (app)");
    await integrations.addTrigger({ kind: "label", label: "pipemaestro", pipeline: "Correção de bug" });

    // Someone adds the label on Forgejo, which sends the webhook.
    await createForgejoIssue({ repo: repoName, ...issue });
    const delivery = { url: webhookUrl, secret, event: "issue_label", id: `e2e-${suffix}`, payload: issueLabelPayload(repoName, issue, fakeForgejo.url) };
    const response = await sendForgejoWebhook(request, delivery);
    expect(response.status()).toBe(202);

    await app.page.goto(connectionPage);
    await waitForLiveView(app.page);
    await expect(app.page.getByTestId(`delivery-status-${key(delivery.id)}`)).toContainText("processada");
    await shot(app.page, "delivery-processed");

    // The agent triages the issue and the task is created on its own.
    await app.page.getByTestId(`delivery-proposal-${key(delivery.id)}`).click();
    const proposal = new ProposalPage(app.page);
    await proposal.waitForProposal();
    await expect(app.page.getByTestId("proposal-issue")).toContainText(`${repoName}#3`);
    const taskUrl = /\/tasks\/[0-9a-f-]+$/;
    await Promise.race([
      app.page.waitForURL(taskUrl, { timeout: 60_000 }),
      proposal.createdTaskLink.waitFor({ timeout: 60_000 }),
    ]);
    if (!taskUrl.test(app.page.url())) await proposal.createdTaskLink.click();
    await app.page.waitForURL(taskUrl);
    await waitForLiveView(app.page);
    await expect(app.page.getByTestId("task-issue")).toContainText(`${repoName}#3`);
    await expect(app.page.getByTestId("task-pipeline-name")).toContainText("Correção de bug");
    await shot(app.page, "task-from-issue");

    // The issue shows the platform took it.
    const state = await forgejoState(repoName);
    expect(state.reactions).toContainEqual({ target: "issue", id: 3, content: "eyes" });
    const labels = state.issues.find((candidate: { number: number }) => candidate.number === 3).labels.map((label: { name: string }) => label.name);
    // The triage label, or already the one of the running task.
    expect(labels.some((name: string) => ["pipemaestro:triando", "pipemaestro:em-andamento", "pipemaestro:pronto"].includes(name))).toBe(true);

    // The issue follows the task: one status comment, and the state label up to "pronto".
    await expect
      .poll(async () => {
        const now = await forgejoState(repoName);
        return now.issues.find((candidate: { number: number }) => candidate.number === 3).labels.map((label: { name: string }) => label.name);
      }, { timeout: 120_000 })
      .toContain("pipemaestro:pronto");
    const done = await forgejoState(repoName);
    const statusComments = done.comments.filter((comment: { body: string }) => comment.body.includes("<!-- pipemaestro:status -->"));
    expect(statusComments).toHaveLength(1);
    expect(statusComments[0].body).toContain("pull request pronto para revisão");
    const doneLabels = done.issues.find((candidate: { number: number }) => candidate.number === 3).labels.map((label: { name: string }) => label.name);
    expect(doneLabels).not.toContain("pipemaestro:em-andamento");

    // The host may deliver the same event twice.
    const again = await sendForgejoWebhook(request, delivery);
    expect(await again.json()).toEqual({ duplicate: true });
  });
});
