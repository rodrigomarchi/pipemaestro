/**
 * @section Projetos
 * @flow A [todo] An admin creates a project by hand: picks a real runner, then one of the directories it offers; the list shows the project's runner and that it is online
 * @flow B [todo] An admin asks the agent to analyse a directory of the runner; the proposal opens with the project form filled (name, setup, test, lint, paths, notes) and nothing is saved until Save
 * @flow C [todo] From the list, "nova tarefa" opens the task form with the project chosen; the task asks for no runner nor directory, runs on the project's runner and shows the project with its snapshot
 */
import { expect, test } from "@playwright/test";
import { bootstrapOperator, uniqueSuffix, userPassword } from "../helpers/env";
import { RunnerProcess } from "../helpers/runnerProcess";
import { shot } from "../helpers/screenshots";
import { waitForLiveView } from "../helpers/liveView";
import { AppPage } from "../pages/AppPage";
import { BackofficePage } from "../pages/BackofficePage";
import { PipelinesPage } from "../pages/PipelinesPage";
import { ProjectsPage } from "../pages/ProjectsPage";
import { ProposalPage } from "../pages/ProposalPage";
import { RunnersPage } from "../pages/RunnersPage";

test.describe("Projects", () => {
  // Real CLI processes: the first one may compile the runner app.
  test.setTimeout(240_000);

  let runner: RunnerProcess;

  test.afterEach(() => runner?.cleanup());

  test("a project is a runner and a directory, and the only choice of where work runs", async ({
    page,
    browser,
  }) => {
    const suffix = uniqueSuffix();
    const workspace = { name: `Projetos ${suffix}`, slug: `projetos-${suffix}` };
    const user = { name: `Paula ${suffix}`, email: `paula-${suffix}@e2e.test` };
    const runnerName = `projetos-${suffix}`;

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

    const projects = new ProjectsPage(app.page);
    const proposal = new ProposalPage(app.page);

    // Flow A: by hand, the runner first, then one of its directories.
    await projects.open(workspace.slug);
    await projects.create({
      name: `Notas ${suffix}`,
      runner: runnerName,
      directory: "notas",
      shot: "project-form-runner",
    });
    await expect(projects.runner("notas")).toContainText(runnerName);
    await expect(projects.status("notas")).toContainText("online");

    // Flow B: the agent studies the directory; the person reviews and saves.
    await projects.analyze(runnerName, "app");
    await proposal.waitForAnswer();
    await expect(proposal.analysis).toContainText("make test");
    await expect(proposal.projectField("name")).toHaveValue("App do fake");
    await expect(proposal.projectField("test")).toHaveValue("make test");
    await expect(proposal.projectField("copy-paths")).toHaveValue("deps");
    await shot(app.page, "project-proposal-review");

    await projects.open(workspace.slug);
    await expect(projects.project("app")).toHaveCount(0);

    await app.page.goBack();
    await proposal.projectField("lint").fill("make check");
    await proposal.saveProposedProject();
    await expect(projects.project("app")).toContainText("App do fake");
    await expect(projects.runner("app")).toContainText(runnerName);
    await shot(app.page, "projects-list");

    // Flow C: a task from the project's shortcut chooses only the project.
    const pipelines = new PipelinesPage(app.page);
    await pipelines.open(workspace.slug);
    await pipelines.createDefaults();

    await projects.open(workspace.slug);
    await projects.newTask("app");
    await expect(app.page.getByTestId("task-runner")).toHaveCount(0);
    await expect(app.page.getByTestId("task-directory")).toHaveCount(0);
    await expect(app.page.getByTestId("task-project")).toHaveValue(/.+/);
    await app.page.getByTestId("task-title").fill(`Tarefa do projeto ${suffix}`);
    await app.page.getByTestId("task-prompt").fill("Grave este prompt.");
    await app.page.getByTestId("task-pipeline").selectOption({ label: "Prompt único" });
    await shot(app.page, "task-form-project");
    await app.page.getByTestId("task-submit").click();
    await app.page.waitForURL(/\/tasks\/[0-9a-f-]+$/);
    await waitForLiveView(app.page);

    // The project, at the pipeline's entry.
    await expect(app.page.getByTestId("task-node-entrada")).toContainText("App do fake");
    await app.page.getByTestId("task-node-entrada").click();
    await app.page.getByTestId("task-node-tab-projeto").click();
    await expect(app.page.getByTestId("task-project")).toContainText("App do fake");
    await expect(app.page.getByTestId("task-project-snapshot")).toContainText("make test");
    await shot(app.page, "task-project");
  });
});
