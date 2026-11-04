import { expect, type Locator, type Page } from "@playwright/test";
import { acceptConfirms, waitForLiveView } from "../helpers/liveView";

/** Pipelines: the workspace's list and the stage editor. */
export class PipelinesPage {
  readonly page: Page;

  constructor(page: Page) {
    this.page = page;
    acceptConfirms(page);
  }

  async open(workspaceSlug: string) {
    await this.page.goto(`/w/${workspaceSlug}/pipelines`);
    await waitForLiveView(this.page);
  }

  async createDefaults() {
    await this.page.getByTestId("create-default-pipelines").click();
    await expect(this.pipeline("Correção de bug")).toBeVisible();
  }

  pipeline(name: string): Locator {
    return this.page.getByTestId(`pipeline-${name}`);
  }

  version(name: string): Locator {
    return this.page.getByTestId(`pipeline-version-${name}`);
  }

  async edit(name: string) {
    await this.page.getByTestId(`pipeline-edit-${name}`).click();
    await expect(this.page.getByTestId("pipeline-name")).toHaveValue(name);
    await waitForLiveView(this.page);
  }

  stagePrompt(index: number): Locator {
    return this.page.getByTestId(`stage-prompt-${index}`);
  }

  /** A button of a prompt editor's toolbar: bold, italic, heading, bullet, numbered, quote, code, link. */
  stagePromptAction(index: number, action: string): Locator {
    return this.page.getByTestId(`stage-prompt-${index}-${action}`);
  }

  /** Inserts a prompt variable at the cursor, from the editor's menu. */
  async insertVariable(index: number, variable: string) {
    await this.page.getByTestId(`stage-prompt-${index}-variables`).click();
    await this.page.getByTestId(`stage-prompt-${index}-variable-${variable}`).click();
  }

  async previewPrompt(index: number) {
    await this.page.getByTestId(`stage-prompt-${index}-preview-tab`).click();
  }

  async writePrompt(index: number) {
    await this.page.getByTestId(`stage-prompt-${index}-write-tab`).click();
  }

  stagePromptPreview(index: number): Locator {
    return this.page.getByTestId(`stage-prompt-${index}-preview`);
  }

  stageGates(index: number): Locator {
    return this.page.getByTestId(`stage-gates-${index}`);
  }

  async save() {
    await this.page.getByTestId("pipeline-save").click();
    await expect(this.page.getByTestId("create-default-pipelines")).toBeVisible();
  }
}
