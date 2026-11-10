import { expect, type Locator, type Page } from "@playwright/test";
import { waitForLiveView } from "../helpers/liveView";

/** The workspace's usage: cost and runs, then its files and retention, read only. */
export class UsagePage {
  readonly page: Page;

  constructor(page: Page) {
    this.page = page;
  }

  async open(workspaceSlug: string) {
    await this.page.goto(`/w/${workspaceSlug}/usage`);
    await expect(this.page.getByTestId("usage-total-cost")).toBeVisible();
    await waitForLiveView(this.page);
  }

  /** The block with the files against the quota and the retention in force. */
  get files(): Locator {
    return this.page.getByTestId("usage-files");
  }

  /** What the workspace's files take, against its quota. */
  get filesBytes(): Locator {
    return this.page.getByTestId("usage-files-bytes");
  }

  /** The retention policies in force. */
  get retention(): Locator {
    return this.page.getByTestId("usage-retention");
  }
}
