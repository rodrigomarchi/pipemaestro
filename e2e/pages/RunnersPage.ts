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

  /** The version a runner announced, in the list. */
  version(name: string): Locator {
    return this.page.getByTestId(`runner-version-${name}`);
  }

  /** The "desatualizado" badge of a runner on an older release, in the list. */
  outdated(name: string): Locator {
    return this.page.getByTestId(`runner-outdated-${name}`);
  }

  /** The link to the runner's binary for a Burrito target (e.g. macos_arm64). */
  download(target: string): Locator {
    return this.page.getByTestId(`runner-download-${target}`);
  }

  /** Opens the "Conectar runner" modal and returns its login command. */
  async openConnect(): Promise<Locator> {
    await this.page.getByTestId("connect-runner").click();
    const login = this.page.getByTestId("connect-login-command");
    await expect(login).toBeVisible();
    return login;
  }

  /** The runner's version the platform requires, in the "Conectar runner" modal. */
  get expectedVersion(): Locator {
    return this.page.getByTestId("runners-expected-version");
  }

  /** The version on the runner's page. */
  get detailVersion(): Locator {
    return this.page.getByTestId("runner-detail-version");
  }

  /** The "desatualizado" badge on the runner's page. */
  get detailOutdated(): Locator {
    return this.page.getByTestId("runner-detail-outdated");
  }

  /** From the runners list, opens the page of the runner named `name`. */
  async openRunner(workspaceSlug: string, name: string) {
    await this.open(workspaceSlug);
    await this.page.getByTestId(`runner-link-${name}`).click();
    await expect(this.recentJobs).toBeVisible();
    await waitForLiveView(this.page);
  }

  /** The runner page's card with the latest jobs it finished. */
  get recentJobs(): Locator {
    return this.page.getByTestId("runner-recent-jobs");
  }

  get noRecentJobs(): Locator {
    return this.page.getByTestId("runner-no-recent-jobs");
  }

  /** One of a finished job's cells on the runner page: link, status, duration, cost, tokens or cache. */
  recentJob(jobId: string, part?: "link" | "status" | "duration" | "cost" | "tokens" | "cache"): Locator {
    return this.page.getByTestId(part ? `runner-recent-job-${part}-${jobId}` : `runner-recent-job-${jobId}`);
  }

  /** The runner's uptime over the last 7 days, in the list. */
  uptime(name: string): Locator {
    return this.page.getByTestId(`runner-uptime-${name}`);
  }

  /** On the runner's page, opens a tab by its `aba` id (visao, conexoes...). */
  async openTab(tab: string) {
    await this.page.getByTestId(`runner-tab-${tab}`).click();
    await expect(this.page).toHaveURL(tab === "visao" ? /\/runners\/[^?]+$/ : new RegExp(`aba=${tab}`));
  }

  /** The "Conexões" tab. */
  get connections(): Locator {
    return this.page.getByTestId("runner-connections");
  }

  /** How each session listed in the "Conexões" tab ended, newest first. */
  get sessionReasons(): Locator {
    return this.page.getByTestId("runner-session-reason");
  }

  get uptimeDay(): Locator {
    return this.page.getByTestId("runner-uptime-day");
  }

  get dropsDay(): Locator {
    return this.page.getByTestId("runner-drops-day");
  }

  /** The "Saúde" tab. */
  get health(): Locator {
    return this.page.getByTestId("runner-health");
  }

  /** The latest value of a measure in the "Saúde" tab: cpu, memory, load or disk. */
  healthValue(measure: "cpu" | "memory" | "load" | "disk"): Locator {
    return this.page.getByTestId(`runner-health-${measure}-value`);
  }

  /** A number of the week's jobs in the "Saúde" tab: runs, failures, setup, queue, gates or outbox. */
  runStat(stat: "runs" | "failures" | "setup" | "queue" | "gates" | "outbox"): Locator {
    return this.page.getByTestId(`runner-stat-${stat}`);
  }

  /** The runner's share of failed jobs over the last 7 days, in the list. */
  failures(name: string): Locator {
    return this.page.getByTestId(`runner-failures-${name}`);
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
