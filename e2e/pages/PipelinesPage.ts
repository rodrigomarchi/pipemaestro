import { expect, type Locator, type Page } from "@playwright/test";
import { acceptConfirms, waitForLiveView } from "../helpers/liveView";
import { clickPageAction } from "../helpers/pageActions";

/** Pipelines: the workspace's list, a pipeline's page and its editor (the diagram and its drawers). */
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
    await clickPageAction(this.page, "create-default-pipelines");
    await expect(this.pipeline("Correção de bug")).toBeVisible();
  }

  pipeline(name: string): Locator {
    return this.page.getByTestId(`pipeline-${name}`);
  }

  version(name: string): Locator {
    return this.page.getByTestId(`pipeline-version-${name}`);
  }

  /** Opens a pipeline's editor: its diagram, every drawer closed. */
  async edit(name: string) {
    await this.page.getByTestId(`pipeline-edit-${name}`).click();
    await expect(this.page.getByTestId("pipeline-name")).toHaveValue(name);
    await waitForLiveView(this.page);
    await this.expectEditor();
  }

  /** The editor's diagram, not the page's: the page's diagram shares its test id. */
  async expectEditor() {
    await expect(this.diagram).toHaveAttribute("data-mode", "edit");
  }

  /** Opens the pipeline's own settings (name, delivery, context) from the diagram's entry. */
  async openEntry() {
    await this.page.getByTestId("diagram-entry").click();
    await expect(this.pagePanel).toBeVisible();
  }

  async closeEntry() {
    await this.page.getByTestId("pipeline-panel-close").click();
    await expect(this.pagePanel).toBeHidden();
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

  get maxCost(): Locator {
    return this.page.getByTestId("pipeline-max-cost");
  }

  stageBudget(index: number): Locator {
    return this.page.getByTestId(`stage-budget-${index}`);
  }

  stageGates(index: number): Locator {
    return this.page.getByTestId(`stage-gates-${index}`);
  }

  /** Opens a stage's "Avançado" block in the form, where its agent, group and context are. */
  async openAdvanced(index: number) {
    await this.page.getByTestId(`stage-advanced-${index}`).click();
    await expect(this.stageContext(index)).toBeVisible();
  }

  /** How a stage starts: "fresh" (from zero) or "continue" (the previous stage's session). */
  stageContext(index: number): Locator {
    return this.page.getByTestId(`stage-context-${index}`);
  }

  /**
   * Saves (from the open drawer, which covers the page, or from the page),
   * lands on the pipeline's page, and goes back to the list.
   */
  async save() {
    const drawerSave = this.page.locator('aside[role="dialog"]:visible [data-testid$="-save"]');
    if ((await drawerSave.count()) > 0) await drawerSave.first().click();
    else await this.page.getByTestId("pipeline-save").click();
    await expect(this.page.getByTestId("pipeline-page-version")).toBeVisible();
    await this.page.getByTestId("pipeline-page-back").click();
    await expect(this.page.getByTestId("page-title")).toHaveText("Pipelines");
  }

  /** A pipeline's page, from the list: the diagram. */
  async openPage(name: string) {
    await this.page.getByTestId(`pipeline-open-${name}`).click();
    await expect(this.page.getByTestId("pipeline-page-version")).toBeVisible();
    await waitForLiveView(this.page);
  }

  get diagram(): Locator {
    return this.page.getByTestId("pipeline-diagram");
  }

  /** A stage's node in the diagram, by position. */
  diagramStage(index: number): Locator {
    return this.page.getByTestId(`diagram-stage-${index}`);
  }

  diagramStep(index: number): Locator {
    return this.page.getByTestId(`diagram-step-${index}`);
  }

  /** Opens a stage's drawer from its node. */
  async selectStage(index: number) {
    await this.page.getByTestId(`diagram-select-${index}`).click();
  }

  /** Opens a stage's drawer in the editor, where its fields are. */
  async openStage(index: number) {
    await this.selectStage(index);
    await expect(this.stagePanel(index)).toBeVisible();
  }

  /** The panel of a stage in the editor (its fields), or of the pipeline's page (its details). */
  stagePanel(index: number): Locator {
    return this.page.getByTestId(`stage-panel-${index}`);
  }

  get pagePanel(): Locator {
    return this.page.getByTestId("pipeline-panel");
  }

  stageName(index: number): Locator {
    return this.page.getByTestId(`stage-name-${index}`);
  }

  /** Inserts a stage at a position from the diagram's `+` (after the last: "Adicionar etapa"); its drawer opens. */
  async insertStageAt(at: number) {
    await this.page.getByTestId(`diagram-insert-${at}`).click();
    await expect(this.stagePanel(at)).toBeVisible();
  }

  async joinGroup(index: number) {
    await this.page.getByTestId(`diagram-join-group-${index}`).click();
  }

  async closePanel(index: number) {
    await this.page.getByTestId(`stage-panel-${index}-close`).click();
    await expect(this.stagePanel(index)).toBeHidden();
  }
}
