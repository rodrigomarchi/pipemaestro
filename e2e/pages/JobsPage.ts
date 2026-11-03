import { expect, type Locator, type Page } from "@playwright/test";
import { acceptConfirms, waitForLiveView } from "../helpers/liveView";

/** Jobs: the workspace's list, the new-job form and one job's live run. */
export class JobsPage {
  readonly page: Page;
  readonly status: Locator;
  readonly events: Locator;
  readonly result: Locator;
  readonly error: Locator;

  constructor(page: Page) {
    this.page = page;
    this.status = page.getByTestId("job-status");
    this.events = page.getByTestId("job-event");
    this.result = page.getByTestId("job-result");
    this.error = page.getByTestId("job-error");
    acceptConfirms(page);
  }

  async open(workspaceSlug: string) {
    await this.page.goto(`/w/${workspaceSlug}/jobs`);
    await waitForLiveView(this.page);
  }

  /**
   * Sends `prompt` to the runner named `runnerName`, waits on the job's page
   * and returns the job's id.
   */
  async create(runnerName: string, prompt: string): Promise<string> {
    await this.page.getByTestId("new-job").click();
    await this.page.getByTestId("job-runner").selectOption({ label: runnerName });
    await this.page.getByTestId("job-prompt").fill(prompt);
    await this.page.getByTestId("job-submit").click();
    await expect(this.page.getByTestId("job-prompt-text")).toHaveText(prompt);
    await waitForLiveView(this.page);
    return new URL(this.page.url()).pathname.split("/").pop()!;
  }

  async cancel() {
    await this.page.getByTestId("job-cancel").click();
  }

  async backToList() {
    await this.page.getByTestId("back-to-jobs").click();
    await expect(this.page.getByTestId("new-job")).toBeVisible();
  }

  /** A job's status badge in the list. */
  listStatus(jobId: string): Locator {
    return this.page.getByTestId(`job-status-${jobId}`);
  }
}
