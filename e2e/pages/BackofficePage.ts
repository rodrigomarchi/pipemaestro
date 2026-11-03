import { expect, type Locator, type Page } from "@playwright/test";
import { acceptConfirms, waitForLiveView } from "../helpers/liveView";

/**
 * The backoffice at /backoffice. Every element is reached by its
 * `data-testid`; per-record elements carry the record's natural key
 * (`member-remove-<email>`, `workspace-edit-<slug>`). Actions wait for the
 * server's confirmation toast, so specs chain them without sleeps.
 */
export class BackofficePage {
  readonly page: Page;
  readonly toasts: Locator;
  readonly title: Locator;

  constructor(page: Page) {
    this.page = page;
    this.toasts = page.getByTestId("toasts");
    this.title = page.getByTestId("page-title");
    acceptConfirms(page);
  }

  async expectToast(text: string | RegExp) {
    await expect(this.toasts).toContainText(text);
  }

  // ── Sign-in ───────────────────────────────────────────────────────────────

  async signIn(email: string, password: string) {
    await this.page.goto("/backoffice/login");
    await waitForLiveView(this.page);
    await this.page.getByTestId("operator-login-email").fill(email);
    await this.page.getByTestId("operator-login-password").fill(password);
    await this.page.getByTestId("operator-login-submit").click();
  }

  async signInExpectingSuccess(email: string, password: string) {
    await this.signIn(email, password);
    await expect(this.title).toHaveText("Workspaces");
    await waitForLiveView(this.page);
  }

  async signOut() {
    await this.page.getByTestId("sidebar-logout").click();
    await expect(this.page.getByTestId("operator-login-email")).toBeVisible();
  }

  async signOutFromAccountMenu() {
    await this.page.getByTestId("account-menu-trigger").click();
    await this.page.getByTestId("account-logout").click();
    await expect(this.page.getByTestId("operator-login-email")).toBeVisible();
  }

  // ── Workspaces ────────────────────────────────────────────────────────────

  async gotoWorkspaces() {
    await this.page.getByTestId("sidebar-workspaces").click();
    await expect(this.title).toHaveText("Workspaces");
  }

  /** Creates a workspace and lands on its page. */
  async createWorkspace(name: string, slug = "") {
    await this.gotoWorkspaces();
    await this.page.getByTestId("new-workspace").click();
    await this.page.getByTestId("workspace-name").fill(name);
    if (slug) await this.page.getByTestId("workspace-slug").fill(slug);
    await this.page.getByTestId("workspace-save").click();
    await this.expectToast(`Workspace ${name} criado.`);
    await expect(this.title).toHaveText(name);
    await waitForLiveView(this.page);
  }

  workspace(slug: string): Locator {
    return this.page.getByTestId(`workspace-${slug}`);
  }

  async openWorkspace(slug: string) {
    await this.gotoWorkspaces();
    await this.workspace(slug).click();
    await waitForLiveView(this.page);
  }

  /** On a workspace page: renames it and returns to the list. */
  async editWorkspace(name: string, slug: string) {
    await this.page.getByTestId("edit-workspace").click();
    await this.page.getByTestId("workspace-name").fill(name);
    await this.page.getByTestId("workspace-slug").fill(slug);
    await this.page.getByTestId("workspace-save").click();
    await this.expectToast(`Workspace ${name} atualizado.`);
  }

  /** On a workspace page: creates a user straight into it. */
  async createMember(name: string, email: string, password: string) {
    await this.page.getByTestId("new-member-name").fill(name);
    await this.page.getByTestId("new-member-email").fill(email);
    await this.page.getByTestId("new-member-password").fill(password);
    await this.page.getByTestId("new-member-submit").click();
    await this.expectToast(`${name} criado e adicionado ao workspace.`);
  }

  /** On a workspace page: adds a user who already exists. */
  async addExistingMember(email: string) {
    await pickComboOption(this.page.getByTestId("add-existing-user"), email);
    await this.page.getByTestId("add-existing-submit").click();
    await this.expectToast(/agora faz parte de/);
  }

  member(email: string): Locator {
    return this.page.getByTestId(`member-${email}`);
  }

  async removeMember(email: string) {
    await this.page.getByTestId(`member-remove-${email}`).click();
    await this.expectToast(/saiu de/);
  }

  // ── Users ─────────────────────────────────────────────────────────────────

  async gotoUsers() {
    await this.page.getByTestId("sidebar-users").click();
    await expect(this.title).toHaveText("Usuários");
  }

  /** Creates a user outside any workspace and lands on their page. */
  async createUser(name: string, email: string, password: string) {
    await this.gotoUsers();
    await this.page.getByTestId("new-user").click();
    await this.page.getByTestId("user-form-name").fill(name);
    await this.page.getByTestId("user-form-email").fill(email);
    await this.page.getByTestId("user-form-password").fill(password);
    await this.page.getByTestId("user-form-submit").click();
    await this.expectToast(`${name} criado. Adicione-o a um workspace.`);
    await expect(this.page.getByTestId("user-email")).toHaveText(email);
    await waitForLiveView(this.page);
  }

  async openUser(email: string) {
    await this.gotoUsers();
    await this.page.getByTestId(`user-${email}`).click();
    await expect(this.page.getByTestId("user-email")).toHaveText(email);
    await waitForLiveView(this.page);
  }

  /** On a user page: adds them to a workspace. */
  async addUserToWorkspace(workspaceName: string) {
    await pickComboOption(this.page.getByTestId("add-to-workspace"), workspaceName);
    await this.page.getByTestId("add-to-workspace-submit").click();
    await this.expectToast(`agora faz parte de ${workspaceName}.`);
  }

  async resetPassword(newPassword: string) {
    await this.page.getByTestId("reset-password").click();
    await this.page.getByTestId("new-password").fill(newPassword);
    await this.page.getByTestId("reset-password-submit").click();
    await this.expectToast(/redefinida\. As sessões abertas foram encerradas\./);
  }

  async disableUser() {
    await this.page.getByTestId("disable-user").click();
    await this.expectToast(/desativado\. As sessões abertas foram encerradas\./);
    await expect(this.page.getByTestId("user-status")).toHaveText("Desativado");
  }

  async enableUser() {
    await this.page.getByTestId("enable-user").click();
    await this.expectToast(/reativado\./);
    await expect(this.page.getByTestId("user-status")).toHaveText("Ativo");
  }

  // ── Operators ─────────────────────────────────────────────────────────────

  async gotoOperators() {
    await this.page.getByTestId("sidebar-operators").click();
    await expect(this.title).toHaveText("Operadores");
  }

  async createOperator(name: string, email: string, password: string) {
    await this.gotoOperators();
    await this.page.getByTestId("new-operator").click();
    await this.page.getByTestId("operator-form-name").fill(name);
    await this.page.getByTestId("operator-form-email").fill(email);
    await this.page.getByTestId("operator-form-password").fill(password);
    await this.page.getByTestId("operator-form-submit").click();
    await this.expectToast(`Operador ${name} criado.`);
    await expect(this.page.getByTestId(`operator-${email}`)).toBeVisible();
  }

  async disableOperator(email: string) {
    await this.page.getByTestId(`operator-disable-${email}`).click();
    await this.expectToast(/desativado\. As sessões abertas foram encerradas\./);
    await expect(this.page.getByTestId(`operator-status-${email}`)).toHaveText("Desativado");
  }
}

/**
 * Picks the option whose label contains `text` in the petal combobox wrapped by
 * `combo` (the element carrying its data-testid): type to filter, click it.
 */
async function pickComboOption(combo: Locator, text: string) {
  const input = combo.getByRole("combobox");
  await input.click();
  await input.fill(text);
  await combo.getByRole("option", { name: text }).click();
}
