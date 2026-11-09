import { expect, type Locator, type Page } from "@playwright/test";
import { waitForLiveView } from "../helpers/liveView";

/** Usage's tabs, by their `aba` parameter, in order. */
export const usageTabs = ["visao", "detalhamento", "etapas", "agente", "qualidade"] as const;
export type UsageTab = (typeof usageTabs)[number];

/**
 * Usage (`/w/:slug/usage`): the filters in the top bar (pipeline, project,
 * period) and the tabs; the quality tab's rates, tables and rankings.
 * Every element is reached by its `data-testid`.
 */
export class UsagePage {
  readonly page: Page;
  readonly pipelineFilter: Locator;
  readonly projectFilter: Locator;
  readonly periodFilter: Locator;
  readonly qualityEmpty: Locator;
  readonly delivered: Locator;
  readonly clean: Locator;
  readonly changed: Locator;
  readonly closed: Locator;
  readonly open: Locator;
  readonly mergeTime: Locator;
  readonly reviewRounds: Locator;
  readonly byPipeline: Locator;
  readonly stages: Locator;
  readonly pauses: Locator;

  constructor(page: Page) {
    this.page = page;
    this.pipelineFilter = page.getByTestId("usage-pipeline");
    this.projectFilter = page.getByTestId("usage-project");
    this.periodFilter = page.getByTestId("usage-period");
    this.qualityEmpty = page.getByTestId("usage-quality-empty");
    this.delivered = page.getByTestId("usage-quality-delivered");
    this.clean = page.getByTestId("usage-quality-clean");
    this.changed = page.getByTestId("usage-quality-changed");
    this.closed = page.getByTestId("usage-quality-closed");
    this.open = page.getByTestId("usage-quality-open");
    this.mergeTime = page.getByTestId("usage-quality-merge-time");
    this.reviewRounds = page.getByTestId("usage-quality-review-rounds");
    this.byPipeline = page.getByTestId("usage-quality-by-pipeline");
    this.stages = page.getByTestId("usage-quality-stages");
    this.pauses = page.getByTestId("usage-quality-pauses");
  }

  /** Opens Usage at a tab. */
  async openTab(workspaceSlug: string, tab: UsageTab) {
    await this.page.goto(`/w/${workspaceSlug}/usage?aba=${tab}`);
    await waitForLiveView(this.page);
    await expect(this.page.getByTestId(`usage-panel-${tab}`)).toBeVisible();
  }

  /** A pipeline's row in the quality tab. */
  pipelineRow(name: string): Locator {
    return this.page.getByTestId(`usage-quality-pipeline-${name}`);
  }

  /** A pipeline's share of pull requests accepted with changes, in the quality tab. */
  pipelineChanged(name: string): Locator {
    return this.page.getByTestId(`usage-quality-pipeline-${name}-changed`);
  }

  async filterPipeline(name: string) {
    await this.pipelineFilter.selectOption(name === "" ? "" : { label: name });
    await waitForLiveView(this.page);
  }

  async filterProject(label: string) {
    await this.projectFilter.selectOption({ label });
    await waitForLiveView(this.page);
  }
}
