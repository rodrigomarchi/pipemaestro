/**
 * @section Tarefas e pipelines
 * @flow A [done] An admin asks the agent, through a real runner, to study a git directory and propose a pipeline for an existing project; the analysis runs in a disposable worktree that leaves the directory untouched and goes away
 * @flow B [done] The proposal shows what the agent understood, the commands it checked and the stages; saving its project opens the pipeline form filled with it, and both are saved
 * @flow C [done] A cost cap the agent proposes never reaches the form: the pipeline opens with no cap per task nor per stage, and saves without one
 */
import { existsSync, readdirSync } from "node:fs";
import { join } from "node:path";
import { expect, test } from "@playwright/test";
import { bootstrapOperator, uniqueSuffix, userPassword } from "../helpers/env";
import { RunnerProcess } from "../helpers/runnerProcess";
import { shot } from "../helpers/screenshots";
import { AppPage } from "../pages/AppPage";
import { BackofficePage } from "../pages/BackofficePage";
import { PipelinesPage } from "../pages/PipelinesPage";
import { ProjectsPage } from "../pages/ProjectsPage";
import { ProposalPage } from "../pages/ProposalPage";
import { RunnersPage } from "../pages/RunnersPage";
import { clickPageAction } from "../helpers/pageActions";

test.describe("Pipeline proposal", () => {
  // Real CLI processes: the first one may compile the runner app.
  test.setTimeout(240_000);

  let runner: RunnerProcess;

  test.afterEach(() => runner?.cleanup());

  test("the agent studies a project and proposes a pipeline", async ({ page, browser }) => {
    const suffix = uniqueSuffix();
    const workspace = { name: `Propostas ${suffix}`, slug: `propostas-${suffix}` };
    const user = { name: `Pietra ${suffix}`, email: `pietra-${suffix}@e2e.test` };
    const runnerName = `analise-${suffix}`;

    const backoffice = new BackofficePage(page);
    await backoffice.signInExpectingSuccess(bootstrapOperator.email, bootstrapOperator.password);
    await backoffice.createWorkspace(workspace.name);
    await backoffice.createMember(user.name, user.email, userPassword);

    const context = await browser.newContext();
    const app = new AppPage(await context.newPage());
    await app.signIn(user.email, userPassword);
    await app.expectBoard(workspace.name);

    runner = new RunnerProcess();
    const root = runner.createCodeRoot();
    runner.start("runner.login", ["--url", app.page.url().replace(/\/w\/.*$/, "")]);
    const [, code] = await runner.waitFor(/digite o código:\s+([A-Z]{4}-[A-Z]{4})/);
    await new RunnersPage(app.page).approve(code, runnerName);
    expect(await runner.waitForExit()).toBe(0);

    runner.start("runner.start", ["--root", root]);
    await runner.waitFor(/Online como/);

    // Flow A: the pipeline is proposed for a project that already exists.
    const projects = new ProjectsPage(app.page);
    await projects.open(workspace.slug);
    await projects.create({ name: "App", runner: runnerName, directory: "app" });

    const pipelines = new PipelinesPage(app.page);
    await pipelines.open(workspace.slug);
    const proposal = new ProposalPage(app.page);
    await clickPageAction(app.page, "generate-pipeline");
    await app.page.getByTestId("proposal-request-text").fill("Entregar issues com testes e um PR.");
    await shot(app.page, "proposal-request");
    await proposal.submitRequest({ project: "App" });
    await proposal.waitForAnswer();

    // The agent ran in a disposable worktree: its file never reached the directory.
    expect(existsSync(join(root, "app", "fake-claude.txt"))).toBe(false);
    await expect
      .poll(() => (existsSync(join(runner.workdir, "scratch")) ? readdirSync(join(runner.workdir, "scratch")) : []))
      .toEqual([]);

    // Flow B: the review.
    await expect(proposal.analysis).toContainText("make test");
    await expect(proposal.checks).toContainText("make lint");
    await expect(proposal.checks).toContainText("Sem alvo de lint");
    await expect(proposal.stage(1)).toContainText("Implementação");
    await expect(await proposal.openStage(1)).toContainText("{{projeto.teste}}");
    await proposal.closeStage();
    await shot(app.page, "proposal-review");

    // The proposal opened on its own; behind it, the proposal as a pipeline.
    await proposal.closeNode("proposta");
    await expect(proposal.node("proposta")).toContainText("Pronta para revisar");
    await expect(proposal.node("ajustes")).toBeVisible();
    await shot(app.page, "proposal-overview");
    await proposal.openNode("agente");
    await shot(app.page, "proposal-agent");
    await proposal.closeNode("agente");
    await proposal.openNode("proposta");

    await proposal.openPipeline();
    await expect(app.page.getByTestId("pipeline-name")).toHaveValue("Entrega proposta");
    await expect(pipelines.stageGates(1)).toHaveValue("{{projeto.teste}}");
    // Flow C: the agent answered with caps; the form opens without them.
    await expect(pipelines.maxCost).toHaveValue("");
    await expect(pipelines.stageBudget(0)).toHaveValue("");
    await shot(app.page, "proposal-pipeline-form");
    await pipelines.save();

    await expect(pipelines.pipeline("Entrega proposta")).toBeVisible();
    await app.page.goto(`/w/${workspace.slug}/proposals`);
    await expect(app.page.getByTestId("proposals")).toContainText("Entregar issues");

    // The proposal does not touch the project.
    await projects.open(workspace.slug);
    await expect(projects.project("app")).toContainText("App");
  });
});
