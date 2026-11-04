import { expect, type Locator, type Page } from "@playwright/test";
import { waitForLiveView } from "../helpers/liveView";

/**
 * Asking the agent for a proposal (pipeline, task, decision, improvement) and
 * reviewing what it proposed.
 */
export class ProposalPage {
  readonly page: Page;

  constructor(page: Page) {
    this.page = page;
  }

  /**
   * Fills the open request form (picks the runner, then one of its git
   * directories, then the text when given) and sends it; waits on the proposal.
   */
  async submitRequest(request: { runner: string; directory: string; text?: string; focus?: string }) {
    await this.page.getByTestId("proposal-request-runner").selectOption({ label: request.runner });
    await expect(this.directoryOptions.filter({ hasText: request.directory })).toHaveCount(1);
    await this.page.getByTestId("proposal-request-directory").selectOption(request.directory);
    if (request.text) await this.page.getByTestId("proposal-request-text").fill(request.text);
    if (request.focus) await this.page.getByTestId("proposal-request-focus").fill(request.focus);
    await this.page.getByTestId("proposal-request-submit").click();
    await this.waitForProposal();
  }

  async waitForProposal() {
    await this.page.waitForURL(/\/proposals\/[0-9a-f-]+$/);
    await waitForLiveView(this.page);
  }

  /** The directory options of the open request form. */
  get directoryOptions(): Locator {
    return this.page.getByTestId("proposal-request-directory").locator("option");
  }

  get status(): Locator {
    return this.page.getByTestId("proposal-status");
  }

  /** Waits until the agent has answered. */
  async waitForAnswer() {
    await expect(this.status).toHaveText("Concluído", { timeout: 60_000 });
  }

  get analysis(): Locator {
    return this.page.getByTestId("proposal-analysis");
  }

  get checks(): Locator {
    return this.page.getByTestId("proposal-checks");
  }

  stage(index: number): Locator {
    return this.page.getByTestId(`proposal-stage-${index}`);
  }

  projectField(name: "name" | "setup" | "test" | "lint" | "copy-paths"): Locator {
    return this.page.getByTestId(`proposal-project-${name}`);
  }

  /** Pipeline: saves the project and lands on the pipeline form filled with the proposal. */
  async saveProject() {
    await this.page.getByTestId("proposal-save-project").click();
    await this.page.waitForURL(/\/pipelines\/new\?proposta=/);
    await waitForLiveView(this.page);
    await expect(this.page.getByTestId("pipeline-from-proposal")).toBeVisible();
  }

  /** Task: opens the new-task form filled with the task the agent wrote. */
  async createTask() {
    await this.page.getByTestId("proposal-create-task").click();
    await this.page.waitForURL(/\/tasks\?proposta=/);
    await waitForLiveView(this.page);
    await expect(this.page.getByTestId("task-from-proposal")).toBeVisible();
  }

  /** Decision: applies `action` with the instructions as they are in the form. */
  async decide(action: "retry" | "advance" | "cancel") {
    await this.page.getByTestId(`proposal-decision-${action}`).click();
    await this.page.waitForURL(/\/tasks\/[0-9a-f-]+$/);
    await waitForLiveView(this.page);
  }

  /** Improve: saves the revised notes. */
  async saveNotes() {
    await this.page.getByTestId("proposal-save-notes").click();
    await expect(this.page.getByTestId("toasts")).toContainText("Notas de");
  }

  /** Improve: opens the pipeline's form filled with the revision. */
  async reviewPipeline() {
    await this.page.getByTestId("proposal-review-pipeline").click();
    await this.page.waitForURL(/\/edit\?proposta=/);
    await waitForLiveView(this.page);
    await expect(this.page.getByTestId("pipeline-from-proposal")).toBeVisible();
  }
}
