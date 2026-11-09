import { expect, type Locator, type Page } from "@playwright/test";
import { acceptConfirms, waitForLiveView } from "../helpers/liveView";
import { selectProject } from "../helpers/projectSelect";
import { clickPageAction } from "../helpers/pageActions";

/**
 * A run's timeline, inside `scope` (the job's `job-events`, a task's
 * `task-events` or a finished attempt's steps): strips of icons, each opening
 * its panel, and blocks of text. Events are keyed by their `seq`.
 */
export class Timeline {
  readonly scope: Locator;

  constructor(scope: Locator) {
    this.scope = scope;
  }

  /** Every icon of the timeline. */
  icons(): Locator {
    return this.scope.getByTestId(/^job-event-icon-\d+$/);
  }

  /** Every block of text (the agent's answers and the result). */
  texts(): Locator {
    return this.scope.getByTestId(/^job-event-\d+$/);
  }

  strip(seq: number): Locator {
    return this.scope.getByTestId(`job-event-strip-${seq}`);
  }

  icon(seq: number): Locator {
    return this.scope.getByTestId(`job-event-icon-${seq}`);
  }

  panel(seq: number): Locator {
    return this.scope.getByTestId(`job-event-panel-${seq}`);
  }

  text(seq: number): Locator {
    return this.scope.getByTestId(`job-event-${seq}`);
  }

  /** Clicks an icon: opens its panel, or closes it when it is the one open. */
  async toggle(seq: number) {
    await this.icon(seq).click();
  }
}

/** Jobs: the workspace's list, the new-job form and one job's live run. */
export class JobsPage {
  readonly page: Page;
  readonly status: Locator;
  readonly timeline: Timeline;
  readonly result: Locator;
  readonly error: Locator;

  constructor(page: Page) {
    this.page = page;
    this.status = page.getByTestId("job-status");
    this.timeline = new Timeline(page.getByTestId("job-events"));
    this.result = page.getByTestId("job-result");
    this.error = page.getByTestId("job-error");
    acceptConfirms(page);
  }

  async open(workspaceSlug: string) {
    await this.page.goto(`/w/${workspaceSlug}/jobs`);
    await waitForLiveView(this.page);
  }

  /**
   * Sends `prompt` to the project named `project` (it runs in a disposable
   * worktree of the project's directory), waits on the job's page and returns
   * the job's id.
   */
  async create(project: string, prompt: string): Promise<string> {
    await clickPageAction(this.page, "new-job");
    await selectProject(this.page.getByTestId("job-project"), project);
    await this.page.getByTestId("job-prompt").fill(prompt);
    await this.page.getByTestId("job-submit").click();
    await expect(this.page.getByTestId("job-prompt-text")).toHaveText(prompt);
    await waitForLiveView(this.page);
    return new URL(this.page.url()).pathname.split("/").pop()!;
  }

  /**
   * Opens a place of the job's pipeline in its drawer: "entrada" (the
   * prompt), "agente" (the timeline, and the audit as tab "auditoria" once it
   * ended), "resultado" or "fim" (its numbers). A drawer already open closes first.
   */
  async openNode(node: "entrada" | "agente" | "resultado" | "fim", tab?: "linha-do-tempo" | "auditoria") {
    await this.closeNodeIfOpen();
    await this.page.getByTestId(`job-node-${node}`).click();
    await expect(this.page.getByTestId(`job-drawer-${node}`)).toBeVisible();
    await expect(this.page).toHaveURL(new RegExp(`[?&]no=${node}(&|$)`));
    if (tab) {
      await this.page.getByTestId(`job-tab-${tab}`).click();
      await expect(this.page.getByTestId(`job-panel-${tab}`)).toBeVisible();
    }
  }

  /** Closes the open drawer, if any, by its button. */
  async closeNodeIfOpen() {
    for (const node of ["entrada", "agente", "resultado", "fim"]) {
      const drawer = this.page.getByTestId(`job-drawer-${node}`);
      if (await drawer.isVisible()) {
        await this.page.getByTestId(`job-drawer-${node}-close`).click();
        await expect(drawer).toBeHidden();
      }
    }
  }

  /** A place of the job's pipeline, with its light facts. */
  node(node: "entrada" | "agente" | "resultado" | "fim"): Locator {
    return this.page.getByTestId(`job-node-${node}`);
  }

  async cancel() {
    await this.closeNodeIfOpen();
    await clickPageAction(this.page, "job-cancel");
  }

  async backToList() {
    await this.closeNodeIfOpen();
    await this.page.getByTestId("back-to-jobs").click();
    await expect(this.page.getByTestId("new-job")).toBeVisible();
  }

  /** A job's status badge in the list. */
  listStatus(jobId: string): Locator {
    return this.page.getByTestId(`job-status-${jobId}`);
  }
}
