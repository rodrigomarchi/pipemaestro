import { expect, type Locator, type Page } from "@playwright/test";
import { fakeForgejo } from "../helpers/fakeForgejo";
import { acceptConfirms, waitForLiveView } from "../helpers/liveView";
import { shot } from "../helpers/screenshots";

/** A test id's natural key from a name, as `PipeMaestroWeb.IntegrationComponents.key/1`. */
export function key(name: string): string {
  return name
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, "-")
    .replace(/^-+|-+$/g, "");
}

/** Integrations: connections to git hosts, their repositories and triggers. */
export class IntegrationsPage {
  readonly page: Page;

  constructor(page: Page) {
    this.page = page;
    acceptConfirms(page);
  }

  async open(workspaceSlug: string) {
    await this.page.goto(`/w/${workspaceSlug}/integrations`);
    await waitForLiveView(this.page);
  }

  /** On a connection's page, opens a tab: "repositorios", "entregas" or "webhook". */
  async openTab(tab: "repositorios" | "entregas" | "webhook") {
    await this.page.getByTestId(`integration-tab-${tab}`).click();
    await expect(this.page.getByTestId(`integration-panel-${tab}`)).toBeVisible();
  }

  /** On a connection's page, the webhook's address and its secret, revealed. */
  async webhook(): Promise<{ url: string; secret: string }> {
    await this.openTab("webhook");
    const url = (await this.page.getByTestId("integration-webhook-url").innerText()).trim();
    await this.page.getByTestId("integration-webhook-secret-reveal").click();
    await expect(this.page.getByTestId("integration-webhook-secret")).not.toContainText("•");
    const secret = (await this.page.getByTestId("integration-webhook-secret").innerText()).trim();
    return { url, secret };
  }

  /** Connects the fake Forgejo with the bot's token and waits for its page. */
  async createTokenConnection(name: string, options: { shot?: string; apiMode?: "control_plane" | "runner" } = {}) {
    await this.page.getByTestId("integration-new").click();
    await waitForLiveView(this.page);
    await this.page.getByTestId("integration-name").fill(name);
    await this.page.getByTestId("integration-base-url").fill(fakeForgejo.url);
    await this.page.getByTestId("integration-token").fill(fakeForgejo.token);
    if (options.apiMode) await this.page.getByTestId("integration-api-mode").selectOption(options.apiMode);
    if (options.shot) await shot(this.page, options.shot);
    await this.page.getByTestId("integration-save").click();
    await expect(this.page.getByTestId("integration-bot")).toContainText("pipemaestro-bot");
    await waitForLiveView(this.page);
  }

  /** Connects the fake Forgejo by OAuth; the fake authorizes at once. */
  async createOAuthConnection(name: string) {
    await this.page.getByTestId("integration-new").click();
    await waitForLiveView(this.page);
    await this.page.getByTestId("integration-auth-kind").selectOption("oauth");
    await expect(this.page.getByTestId("integration-oauth-redirect")).toContainText("/integrations/oauth/callback");
    await this.page.getByTestId("integration-name").fill(name);
    await this.page.getByTestId("integration-base-url").fill(fakeForgejo.url);
    await this.page.getByTestId("integration-oauth-client-id").fill("e2e-client");
    await this.page.getByTestId("integration-oauth-client-secret").fill("e2e-secret");
    await this.page.getByTestId("integration-save").click();
    await expect(this.page.getByTestId("integration-bot")).toContainText("ana-forgejo");
    await waitForLiveView(this.page);
  }

  /** From a connection's page, links `fullName` to the project in `directory`. */
  async linkRepo(fullName: string, projectLabel: string, options: { shot?: string } = {}) {
    await this.openTab("repositorios");
    await this.page.getByTestId("repo-link-open").click();
    await this.page.getByTestId("repo-search").fill(fullName);
    await this.page.getByTestId(`repo-option-${key(fullName)}`).click();
    await this.page.getByTestId("repo-project").selectOption({ label: projectLabel });
    if (options.shot) await shot(this.page, options.shot);
    await this.page.getByTestId("repo-link-save").click();
    await expect(this.page.getByTestId("trigger-new")).toBeVisible();
    await waitForLiveView(this.page);
  }

  /** From a repository's page, adds a trigger and waits for it in the list. */
  async addTrigger(
    trigger: { kind: "label" | "comment" | "opened"; label?: string; command?: string; pipeline?: string; autoApprove?: boolean },
    options: { shot?: string } = {},
  ) {
    await this.page.getByTestId("trigger-new").click();
    await this.page.getByTestId("trigger-kind").selectOption(trigger.kind);
    if (trigger.label) await this.page.getByTestId("trigger-label").fill(trigger.label);
    if (trigger.command) await this.page.getByTestId("trigger-command").fill(trigger.command);
    if (trigger.pipeline) {
      await this.page.getByTestId("trigger-pipeline").selectOption({ label: trigger.pipeline });
      await expect(this.page.getByTestId("trigger-pipeline-preview")).toBeVisible();
    }
    if (trigger.autoApprove === false) await this.page.getByTestId("trigger-auto-approve").uncheck();
    if (options.shot) await shot(this.page, options.shot);
    await this.page.getByTestId("trigger-save").click();
    await expect(this.trigger(trigger)).toBeVisible();
  }

  trigger(trigger: { kind: string; label?: string; command?: string }): Locator {
    const id =
      trigger.kind === "label"
        ? `trigger-label-${key(trigger.label || "")}`
        : trigger.kind === "comment"
          ? `trigger-comment-${key(trigger.command || "")}`
          : "trigger-opened";
    return this.page.getByTestId(id);
  }
}
