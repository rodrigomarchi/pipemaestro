import { expect, type Locator, type Page } from "@playwright/test";
import { waitForLiveView } from "../helpers/liveView";
import { selectProject } from "../helpers/projectSelect";

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
   * Fills the open request form (picks the project, then the text when given)
   * and sends it; waits on the proposal.
   */
  async submitRequest(request: {
    project: string;
    text?: string;
    focus?: string;
    /** Task: the pipeline to write for (by default the agent picks one). */
    pipeline?: string;
    /** Task: whether to create and start the task without review (on by default). */
    autoApprove?: boolean;
  }) {
    await selectProject(this.page.getByTestId("proposal-request-project"), request.project);
    if (request.text) await this.page.getByTestId("proposal-request-text").fill(request.text);
    if (request.focus) await this.page.getByTestId("proposal-request-focus").fill(request.focus);
    if (request.pipeline)
      await this.page.getByTestId("proposal-request-pipeline").selectOption({ label: request.pipeline });
    // Petal's switch hides its input (sr-only), which a pointer cannot land on: the keyboard toggles it.
    if (request.autoApprove !== undefined) {
      const autoApprove = this.page.getByTestId("proposal-request-auto-approve");
      if ((await autoApprove.isChecked()) !== request.autoApprove) {
        await autoApprove.focus();
        await this.page.keyboard.press("Space");
      }
      await expect(autoApprove).toBeChecked({ checked: request.autoApprove });
    }
    await this.page.getByTestId("proposal-request-submit").click();
    await this.waitForProposal();
  }

  async waitForProposal() {
    await this.page.waitForURL(/\/proposals\/[0-9a-f-]+$/);
    await waitForLiveView(this.page);
  }

  /** The project options of the open request form. */
  get projectOptions(): Locator {
    return this.page.getByTestId("proposal-request-project").locator("option");
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

  /** A stage of the proposed pipeline, as a node of its diagram. */
  stage(index: number): Locator {
    return this.page.getByTestId("proposal-diagram").getByTestId(`diagram-stage-${index}`);
  }

  /** Opens a proposed stage's details (prompt, gates) in the side panel. */
  async openStage(index: number): Promise<Locator> {
    await this.page.getByTestId("proposal-diagram").getByTestId(`diagram-select-${index}`).click();
    const panel = this.page.getByTestId("proposal-panel");
    await expect(panel).toBeVisible();
    return panel;
  }

  async closeStage() {
    await this.page.getByTestId("proposal-panel-close").click();
    await expect(this.page.getByTestId("proposal-panel")).toHaveCount(0);
  }

  /** Project: a field of the project form the agent filled. */
  projectField(name: "name" | "setup" | "test" | "lint" | "copy-paths" | "notes"): Locator {
    return this.page.getByTestId(`proposal-project-${name}`);
  }

  /** Pipeline: lands on the pipeline form filled with the proposal. */
  async openPipeline() {
    await this.page.getByTestId("proposal-open-pipeline").click();
    await this.page.waitForURL(/\/pipelines\/new\?proposta=/);
    await waitForLiveView(this.page);
    await expect(this.page.getByTestId("pipeline-from-proposal")).toBeVisible();
    await this.page.getByTestId("pipeline-view-form").click();
    await expect(this.page.getByTestId("stage-card-0")).toBeVisible();
  }

  /** Project: saves the project as reviewed and lands on the list of projects. */
  async saveProposedProject() {
    await this.page.getByTestId("proposal-save-project").click();
    await this.page.waitForURL(/\/projects$/);
    await waitForLiveView(this.page);
  }

  /** Task: opens the new-task form filled with the task the agent wrote. */
  async createTask() {
    await this.page.getByTestId("proposal-create-task").click();
    await this.page.waitForURL(/\/tasks\?proposta=/);
    await waitForLiveView(this.page);
    await expect(this.page.getByTestId("task-from-proposal")).toBeVisible();
  }

  /** Task: the link to the task created from the proposal without review. */
  get createdTaskLink(): Locator {
    return this.page.getByTestId("proposal-created-task-link");
  }

  /** Task: why the proposal was left for review instead of created on its own. */
  get autoApproveSkipped(): Locator {
    return this.page.getByTestId("proposal-auto-approve-skipped");
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
    await this.page.getByTestId("pipeline-view-form").click();
    await expect(this.page.getByTestId("stage-card-0")).toBeVisible();
  }
}
