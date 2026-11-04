import { expect, type Locator, type Page } from "@playwright/test";
import { waitForLiveView } from "../helpers/liveView";

/** Asking the agent for a pipeline and its project, and reviewing what it proposed. */
export class ProposalPage {
  readonly page: Page;

  constructor(page: Page) {
    this.page = page;
  }

  /** From the pipelines page: picks the runner and directory, writes the request and sends it. */
  async request(runnerName: string, directory: string, request: string) {
    await this.page.getByTestId("generate-pipeline").click();
    await this.page.getByTestId("generate-runner").selectOption({ label: runnerName });
    await expect(this.page.getByTestId("generate-directory").locator("option", { hasText: directory })).toHaveCount(1);
    await this.page.getByTestId("generate-directory").selectOption(directory);
    await this.page.getByTestId("generate-request").fill(request);
    await this.page.getByTestId("generate-submit").click();
    await this.page.waitForURL(/\/pipelines\/proposals\//);
    await waitForLiveView(this.page);
  }

  /** The directory options the generate form offers. */
  get directoryOptions(): Locator {
    return this.page.getByTestId("generate-directory").locator("option");
  }

  get status(): Locator {
    return this.page.getByTestId("proposal-status");
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

  /** Saves the project and lands on the pipeline form filled with the proposal. */
  async saveProject() {
    await this.page.getByTestId("proposal-save-project").click();
    await this.page.waitForURL(/\/pipelines\/new\?proposta=/);
    await waitForLiveView(this.page);
    await expect(this.page.getByTestId("pipeline-from-proposal")).toBeVisible();
  }
}
