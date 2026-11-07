import { expect, type Locator, type Page } from "@playwright/test";
import { waitForLiveView } from "../helpers/liveView";

/** The board's tabs, by their `aba` parameter, in order. */
export const boardTabs = ["visao", "tarefas", "decisoes", "atividade", "executores"] as const;
export type BoardTab = (typeof boardTabs)[number];

/**
 * The customer side: sign-in at /login, the workspace picker and the board.
 * Every element is reached by its `data-testid`.
 */
export class AppPage {
  readonly page: Page;
  readonly toasts: Locator;
  readonly title: Locator;
  readonly currentWorkspace: Locator;

  constructor(page: Page) {
    this.page = page;
    this.toasts = page.getByTestId("toasts");
    this.title = page.getByTestId("page-title");
    this.currentWorkspace = page.getByTestId("current-workspace");
  }

  async signIn(email: string, password: string, { remember = false } = {}) {
    await this.page.goto("/login");
    await waitForLiveView(this.page);
    await this.page.getByTestId("login-email").fill(email);
    await this.page.getByTestId("login-password").fill(password);
    await this.page.getByTestId("login-remember").setChecked(remember);
    await this.page.getByTestId("login-submit").click();
  }

  async expectRejected() {
    await expect(this.toasts).toContainText("E-mail ou senha inválidos.");
    await expect(this.page.getByTestId("login-email")).toBeVisible();
  }

  async expectSignInPage() {
    await expect(this.page.getByTestId("login-email")).toBeVisible();
  }

  async expectBoard(workspaceName: string) {
    await expect(this.title).toHaveText("Board");
    await expect(this.currentWorkspace).toHaveText(workspaceName);
    await waitForLiveView(this.page);
  }

  workspaceCard(slug: string): Locator {
    return this.page.getByTestId(`workspace-card-${slug}`);
  }

  async pickWorkspace(slug: string, name: string) {
    await this.workspaceCard(slug).click();
    await this.expectBoard(name);
  }

  async switchWorkspace(slug: string, name: string) {
    await this.page.getByTestId("workspace-switcher-trigger").click();
    await this.page.getByTestId(`workspace-switcher-item-${slug}`).click();
    await this.expectBoard(name);
  }

  /** Opens the board at one of its tabs; the overview is the default. */
  async openBoard(workspaceSlug: string, tab?: BoardTab) {
    const query = tab && tab !== "visao" ? `?aba=${tab}` : "";
    await this.page.goto(`/w/${workspaceSlug}${query}`);
    await expect(this.title).toHaveText("Board");
    await waitForLiveView(this.page);
    await this.expectBoardTab(tab ?? "visao");
  }

  /** One of the board's tabs, by its `aba` parameter. */
  boardTab(tab: BoardTab): Locator {
    return this.page.getByTestId(`board-tab-${tab}`);
  }

  /** The counter on a board tab: alerts, decisions waiting or runners online/total. */
  boardTabCount(tab: "visao" | "decisoes" | "executores"): Locator {
    return this.page.getByTestId(`board-tab-count-${tab}`);
  }

  /** Switches the board to a tab, without reloading the page. */
  async openBoardTab(tab: BoardTab) {
    await this.boardTab(tab).click();
    await this.expectBoardTab(tab);
  }

  async expectBoardTab(tab: BoardTab) {
    await expect(this.boardTab(tab)).toHaveAttribute("aria-selected", "true");
  }

  /** One of the board's "needs attention" alerts: "offline", "limit", "budget" or "overdue". */
  boardAlert(kind: "offline" | "limit" | "budget" | "overdue", taskId: string): Locator {
    return this.page.getByTestId(`board-alert-${kind}-${taskId}`);
  }

  /** The board's alert about a degraded runner, by its name. */
  degradedAlert(runnerName: string): Locator {
    return this.page.getByTestId(`board-alert-degraded-${runnerName}`);
  }

  async openAccountMenu() {
    await this.page.getByTestId("account-menu-trigger").click();
    await expect(this.page.getByTestId("account-email")).toBeVisible();
  }

  async signOut() {
    await this.page.getByTestId("sidebar-logout").click();
    await this.expectSignInPage();
  }

  async signOutFromAccountMenu() {
    await this.openAccountMenu();
    await this.page.getByTestId("account-logout").click();
    await this.expectSignInPage();
  }
}
