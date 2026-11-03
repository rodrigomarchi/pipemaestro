import { expect, type Locator, type Page } from "@playwright/test";
import { acceptConfirms, waitForLiveView } from "../helpers/liveView";
import { shot } from "../helpers/screenshots";

/** Runner screens on the customer side: activation and the workspace's runners. */
export class RunnersPage {
  readonly page: Page;
  readonly toasts: Locator;

  constructor(page: Page) {
    this.page = page;
    this.toasts = page.getByTestId("toasts");
    acceptConfirms(page);
  }

  /** Types the code a runner printed and approves it under `name`. */
  async approve(code: string, name: string) {
    await this.page.goto("/runners/activate");
    await waitForLiveView(this.page);
    await this.page.getByTestId("activate-code").fill(code);
    await this.page.getByTestId("activate-lookup").click();
    await expect(this.page.getByTestId("activate-request")).toBeVisible();
    await this.page.getByTestId("activate-name").fill(name);
    await shot(this.page, "runner-request");
    await this.page.getByTestId("activate-approve").click();
    await expect(this.page.getByTestId("activate-approved")).toContainText(name);
  }

  async open(workspaceSlug: string) {
    await this.page.goto(`/w/${workspaceSlug}/runners`);
    await waitForLiveView(this.page);
  }

  runner(name: string): Locator {
    return this.page.getByTestId(`runner-${name}`);
  }

  status(name: string): Locator {
    return this.page.getByTestId(`runner-status-${name}`);
  }

  async rename(from: string, to: string) {
    await this.page.getByTestId(`runner-rename-${from}`).click();
    await this.page.getByTestId("rename-name").fill(to);
    await this.page.getByTestId("rename-submit").click();
    await expect(this.toasts).toContainText(`Runner renomeado para ${to}.`);
  }

  async revoke(name: string) {
    await this.page.getByTestId(`runner-revoke-${name}`).click();
    await expect(this.toasts).toContainText(`Runner ${name} revogado.`);
  }
}
