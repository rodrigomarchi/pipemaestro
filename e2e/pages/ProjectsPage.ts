import { expect, type Locator, type Page } from "@playwright/test";
import { acceptConfirms, waitForLiveView } from "../helpers/liveView";
import { shot } from "../helpers/screenshots";

/** Projects: a runner, one of its directories, and how to work in it. */
export class ProjectsPage {
  readonly page: Page;

  constructor(page: Page) {
    this.page = page;
    acceptConfirms(page);
  }

  async open(workspaceSlug: string) {
    await this.page.goto(`/w/${workspaceSlug}/projects`);
    await waitForLiveView(this.page);
  }

  /** Creates a project from the form and waits for it in the list. */
  async create(project: {
    name: string;
    /** The runner the project lives on; its directories fill the next select. */
    runner: string;
    directory: string;
    setup?: string;
    test?: string;
    lint?: string;
    copyPaths?: string;
    /** Captures the filled form under this name (E2E_SHOTS). */
    shot?: string;
  }) {
    await this.page.getByTestId("new-project").click();
    await waitForLiveView(this.page);
    await this.page.getByTestId("project-name").fill(project.name);
    await this.pickRunner(project.runner);
    await this.page.getByTestId("project-directory").selectOption(project.directory);
    if (project.setup) await this.page.getByTestId("project-setup").fill(project.setup);
    if (project.test) await this.page.getByTestId("project-test").fill(project.test);
    if (project.lint) await this.page.getByTestId("project-lint").fill(project.lint);
    if (project.copyPaths) await this.page.getByTestId("project-copy-paths").fill(project.copyPaths);
    if (project.shot) await shot(this.page, project.shot);
    await this.page.getByTestId("project-save").click();
    await expect(this.project(project.directory)).toContainText(project.name);
  }

  /** Edits an existing project's commands and waits for the list. */
  async configure(
    directory: string,
    commands: { setup?: string; test?: string; lint?: string; copyPaths?: string; shot?: string },
  ) {
    await this.page.getByTestId(`project-edit-${directory}`).click();
    await waitForLiveView(this.page);
    if (commands.setup) await this.page.getByTestId("project-setup").fill(commands.setup);
    if (commands.test) await this.page.getByTestId("project-test").fill(commands.test);
    if (commands.lint) await this.page.getByTestId("project-lint").fill(commands.lint);
    if (commands.copyPaths) await this.page.getByTestId("project-copy-paths").fill(commands.copyPaths);
    if (commands.shot) await shot(this.page, commands.shot);
    await this.page.getByTestId("project-save").click();
    await expect(this.project(directory)).toBeVisible();
  }

  /** Picks the runner in the open form and waits for its directories. */
  async pickRunner(runner: string) {
    await this.page.getByTestId("project-runner").selectOption({ label: runner });
    await expect(this.page.getByTestId("project-directory").locator("option")).not.toHaveCount(1);
  }

  /**
   * Opens the new-project form, picks the runner and the directory, and asks
   * the agent to study it; waits on the proposal.
   */
  async analyze(runner: string, directory: string) {
    await this.page.getByTestId("new-project").click();
    await waitForLiveView(this.page);
    await this.pickRunner(runner);
    await this.page.getByTestId("project-directory").selectOption(directory);
    await this.page.getByTestId("project-analyze").click();
    await this.page.waitForURL(/\/proposals\/[0-9a-f-]+$/);
    await waitForLiveView(this.page);
  }

  project(directory: string): Locator {
    return this.page.getByTestId(`project-${directory}`);
  }

  /** The project's runner, by name. */
  runner(directory: string): Locator {
    return this.page.getByTestId(`project-runner-${directory}`);
  }

  /** Whether the project's runner is online. */
  status(directory: string): Locator {
    return this.page.getByTestId(`project-status-${directory}`);
  }

  /** The warning of a project whose runner no longer offers its directory. */
  directoryGone(directory: string): Locator {
    return this.page.getByTestId(`project-directory-gone-${directory}`);
  }

  /** The latest tasks of the project. */
  recentTasks(directory: string): Locator {
    return this.page.getByTestId(`project-recent-tasks-${directory}`);
  }

  /** Opens the new-job form with the project already chosen. */
  async newJob(directory: string) {
    await this.page.getByTestId(`project-new-job-${directory}`).click();
    await this.page.waitForURL(/\/jobs\?project_id=/);
    await waitForLiveView(this.page);
  }

  /** Opens the new-task form with the project already chosen. */
  async newTask(directory: string) {
    await this.page.getByTestId(`project-new-task-${directory}`).click();
    await this.page.waitForURL(/\/tasks\?project_id=/);
    await waitForLiveView(this.page);
  }
}
