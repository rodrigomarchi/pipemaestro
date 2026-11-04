/**
 * @section Execuções
 * @flow A [done] A member sends a prompt to an online runner: the runner runs the agent CLI in its workdir and the run shows live, ending with the result, cost and duration
 * @flow B [done] A member cancels a running job: the runner stops the agent and the job ends canceled
 * @flow C [done] A job whose agent fails ends failed with the CLI's error; the list shows every job's status
 * @flow D [done] The timeline shows the events without text as icons in a strip, each opening its panel below it; an open panel stays open while the strip grows live
 */
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { expect, test } from "@playwright/test";
import { bootstrapOperator, uniqueSuffix, userPassword } from "../helpers/env";
import { RunnerProcess } from "../helpers/runnerProcess";
import { shot } from "../helpers/screenshots";
import { AppPage } from "../pages/AppPage";
import { BackofficePage } from "../pages/BackofficePage";
import { JobsPage } from "../pages/JobsPage";
import { RunnersPage } from "../pages/RunnersPage";

test.describe("Job execution", () => {
  // Real CLI processes: the first one may compile the runner app.
  test.setTimeout(240_000);

  let runner: RunnerProcess;

  test.afterEach(() => runner?.cleanup());

  test("runs, cancels and fails jobs on a real runner", async ({ page, browser }) => {
    const suffix = uniqueSuffix();
    const workspace = { name: `Jobs ${suffix}`, slug: `jobs-${suffix}` };
    const user = { name: `Joana ${suffix}`, email: `joana-${suffix}@e2e.test` };
    const runnerName = `exec-${suffix}`;

    const backoffice = new BackofficePage(page);
    await backoffice.signInExpectingSuccess(bootstrapOperator.email, bootstrapOperator.password);
    await backoffice.createWorkspace(workspace.name);
    await backoffice.createMember(user.name, user.email, userPassword);

    const context = await browser.newContext();
    const app = new AppPage(await context.newPage());
    await app.signIn(user.email, userPassword);
    await app.expectBoard(workspace.name);

    runner = new RunnerProcess();
    runner.start("runner.login", ["--url", app.page.url().replace(/\/w\/.*$/, "")]);
    const [, code] = await runner.waitFor(/digite o código:\s+([A-Z]{4}-[A-Z]{4})/);
    await new RunnersPage(app.page).approve(code, runnerName);
    expect(await runner.waitForExit()).toBe(0);

    runner.start("runner.start");
    await runner.waitFor(/Online como/);

    const jobs = new JobsPage(app.page);
    await jobs.open(workspace.slug);
    await expect(app.page.getByTestId("no-jobs")).toBeVisible();

    // Flow A: a job runs to the end.
    const prompt = `Grave este prompt no workdir (${suffix})`;
    const doneId = await jobs.create(runnerName, prompt);
    await expect(jobs.status).toHaveText("Concluído");
    await expect(jobs.result).toContainText("fake-claude.txt");
    await expect(app.page.getByTestId("job-cost")).toHaveText("US$ 0.0042");
    await expect(app.page.getByTestId("job-duration")).toHaveText("1 s");
    await runner.waitFor(new RegExp(`Job ${doneId} concluído`));
    expect(readFileSync(join(runner.workdir, "fake-claude.txt"), "utf8")).toBe(`${prompt}\n`);

    // The session, thinking, the Write and its result are icons in one strip;
    // the answer and the result are blocks of text.
    const timeline = jobs.timeline;
    await expect(timeline.icons()).toHaveCount(4);
    await expect(timeline.strip(1).getByTestId(/^job-event-icon-\d+$/)).toHaveCount(4);
    await expect(timeline.texts()).toHaveCount(2);
    for (const seq of [1, 2, 3, 4]) {
      await expect(timeline.icon(seq)).toHaveAttribute("data-state", "normal");
      await expect(timeline.panel(seq)).toBeHidden();
    }
    await expect(timeline.icon(3)).toHaveAttribute("data-type", "tool_use");
    await shot(app.page, "job-succeeded");

    // An icon opens its panel; another switches to its own; the same closes it.
    await timeline.toggle(3);
    await expect(timeline.panel(3)).toBeVisible();
    await expect(timeline.panel(3)).toContainText("fake-claude.txt");
    await expect(timeline.icon(3)).toHaveAttribute("aria-expanded", "true");
    await shot(app.page.getByTestId("job-events"), "job-event-panel-open");

    await timeline.toggle(2);
    await expect(timeline.panel(2)).toBeVisible();
    await expect(timeline.panel(3)).toBeHidden();
    await expect(timeline.icon(3)).toHaveAttribute("aria-expanded", "false");

    await timeline.toggle(2);
    await expect(timeline.panel(2)).toBeHidden();
    await expect(timeline.icon(2)).toHaveAttribute("aria-expanded", "false");

    // At a narrow width the strip and an open panel still fit the card.
    const viewport = app.page.viewportSize();
    await app.page.setViewportSize({ width: 800, height: viewport?.height ?? 720 });
    await timeline.toggle(3);
    await shot(app.page, "job-timeline-narrow");
    await timeline.toggle(3);
    if (viewport) await app.page.setViewportSize(viewport);

    // The audit: what the run reported, and the CLI's telemetry relayed by the
    // runner (the Write took 12 ms in the fake CLI's export).
    const audit = app.page.getByTestId("job-audit");
    await expect(app.page.getByTestId("job-audit-session")).toContainText("fake-session");
    await expect(app.page.getByTestId("job-audit-cache-hit")).toHaveText("91%");
    await expect(app.page.getByTestId("job-audit-tool-calls-Write")).toHaveText("1");
    await expect(app.page.getByTestId("job-audit-tool-time-Write")).toHaveText("12 ms");
    await expect(app.page.getByTestId("job-audit-api")).toContainText("1 requisição");
    await expect(app.page.getByTestId("job-audit-mcp-grafana")).toBeAttached();
    await shot(audit, "job-audit");

    // Flow D: an open panel stays open while its strip grows live.
    await jobs.backToList();
    await jobs.create(runnerName, "Use mais uma ferramenta [gotejando]");
    await expect(jobs.timeline.icon(4)).toBeVisible();
    await jobs.timeline.toggle(2);
    await expect(jobs.timeline.panel(2)).toBeVisible();
    await expect(jobs.timeline.strip(1).getByTestId("job-event-icon-5")).toBeVisible({ timeout: 15_000 });
    await expect(jobs.timeline.panel(2)).toBeVisible();
    await expect(jobs.timeline.icon(2)).toHaveAttribute("aria-expanded", "true");
    await shot(app.page.getByTestId("job-events"), "job-event-panel-open-live");
    await expect(jobs.status).toHaveText("Concluído");
    await expect(jobs.timeline.panel(2)).toBeVisible();

    // Flow B: a long job is canceled while it runs.
    await jobs.backToList();
    const slowId = await jobs.create(runnerName, "Demore bastante [lento]");
    await expect(jobs.status).toHaveText("Executando");
    await expect(jobs.timeline.icons()).toHaveCount(4);
    await shot(app.page, "job-running");
    await jobs.cancel();
    await expect(jobs.status).toHaveText("Cancelado");
    await runner.waitFor(new RegExp(`Job ${slowId} cancelado`));
    await shot(app.page, "job-canceled");

    // Flow C: the agent fails.
    await jobs.backToList();
    const failedId = await jobs.create(runnerName, "Quebre de propósito [falha]");
    await expect(jobs.status).toHaveText("Falhou");
    await expect(jobs.error).toContainText("falha simulada");
    await shot(app.page, "job-failed");

    await jobs.backToList();
    await expect(jobs.listStatus(doneId)).toHaveText("Concluído");
    await expect(jobs.listStatus(slowId)).toHaveText("Cancelado");
    await expect(jobs.listStatus(failedId)).toHaveText("Falhou");
    await shot(app.page, "jobs-list");

    await context.close();
  });
});
