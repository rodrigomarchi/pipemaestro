import { expect, type Locator, type Page } from "@playwright/test";
import { acceptConfirms, waitForLiveView } from "../helpers/liveView";
import { shot } from "../helpers/screenshots";

/** Projects: what the platform knows about each code directory. */
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
    directory: string;
    setup?: string;
    test?: string;
    copyPaths?: string;
    /** Captures the filled form under this name (E2E_SHOTS). */
    shot?: string;
  }) {
    await this.page.getByTestId("new-project").click();
    await waitForLiveView(this.page);
    await this.page.getByTestId("project-name").fill(project.name);
    await this.page.getByTestId("project-directory").selectOption(project.directory);
    if (project.setup) await this.page.getByTestId("project-setup").fill(project.setup);
    if (project.test) await this.page.getByTestId("project-test").fill(project.test);
    if (project.copyPaths) await this.page.getByTestId("project-copy-paths").fill(project.copyPaths);
    if (project.shot) await shot(this.page, project.shot);
    await this.page.getByTestId("project-save").click();
    await expect(this.project(project.directory)).toContainText(project.name);
  }

  project(directory: string): Locator {
    return this.page.getByTestId(`project-${directory}`);
  }
}
