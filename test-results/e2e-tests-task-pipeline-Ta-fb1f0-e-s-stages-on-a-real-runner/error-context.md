# Instructions

- Following Playwright test failed.
- Explain why, be concise, respect Playwright best practices.
- Provide a snippet of code with the fix, if possible.

# Test info

- Name: e2e/tests/task-pipeline.spec.ts >> Task pipeline >> runs a task through the pipeline's stages on a real runner
- Location: e2e/tests/task-pipeline.spec.ts:33:7

# Error details

```
Error: page.goto: Protocol error (Page.navigate): Cannot navigate to invalid URL
Call log:
  - navigating to "/backoffice/login", waiting until "load"

```

# Test source

```ts
  1   | import { expect, type Locator, type Page } from "@playwright/test";
  2   | import { acceptConfirms, waitForLiveView } from "../helpers/liveView";
  3   | 
  4   | /**
  5   |  * The backoffice at /backoffice. Every element is reached by its
  6   |  * `data-testid`; per-record elements carry the record's natural key
  7   |  * (`member-remove-<email>`, `workspace-edit-<slug>`). Actions wait for the
  8   |  * server's confirmation toast, so specs chain them without sleeps.
  9   |  */
  10  | export class BackofficePage {
  11  |   readonly page: Page;
  12  |   readonly toasts: Locator;
  13  |   readonly title: Locator;
  14  | 
  15  |   constructor(page: Page) {
  16  |     this.page = page;
  17  |     this.toasts = page.getByTestId("toasts");
  18  |     this.title = page.getByTestId("page-title");
  19  |     acceptConfirms(page);
  20  |   }
  21  | 
  22  |   async expectToast(text: string | RegExp) {
  23  |     await expect(this.toasts).toContainText(text);
  24  |   }
  25  | 
  26  |   // ── Sign-in ───────────────────────────────────────────────────────────────
  27  | 
  28  |   async signIn(email: string, password: string) {
> 29  |     await this.page.goto("/backoffice/login");
      |                     ^ Error: page.goto: Protocol error (Page.navigate): Cannot navigate to invalid URL
  30  |     await waitForLiveView(this.page);
  31  |     await this.page.getByTestId("operator-login-email").fill(email);
  32  |     await this.page.getByTestId("operator-login-password").fill(password);
  33  |     await this.page.getByTestId("operator-login-submit").click();
  34  |   }
  35  | 
  36  |   async signInExpectingSuccess(email: string, password: string) {
  37  |     await this.signIn(email, password);
  38  |     await expect(this.title).toHaveText("Workspaces");
  39  |     await waitForLiveView(this.page);
  40  |   }
  41  | 
  42  |   async signOut() {
  43  |     await this.page.getByTestId("sidebar-logout").click();
  44  |     await expect(this.page.getByTestId("operator-login-email")).toBeVisible();
  45  |   }
  46  | 
  47  |   async signOutFromAccountMenu() {
  48  |     await this.page.getByTestId("account-menu-trigger").click();
  49  |     await this.page.getByTestId("account-logout").click();
  50  |     await expect(this.page.getByTestId("operator-login-email")).toBeVisible();
  51  |   }
  52  | 
  53  |   // ── Workspaces ────────────────────────────────────────────────────────────
  54  | 
  55  |   async gotoWorkspaces() {
  56  |     await this.page.getByTestId("sidebar-workspaces").click();
  57  |     await expect(this.title).toHaveText("Workspaces");
  58  |   }
  59  | 
  60  |   /** Creates a workspace and lands on its page. */
  61  |   async createWorkspace(name: string, slug = "") {
  62  |     await this.gotoWorkspaces();
  63  |     await this.page.getByTestId("new-workspace").click();
  64  |     await this.page.getByTestId("workspace-name").fill(name);
  65  |     if (slug) await this.page.getByTestId("workspace-slug").fill(slug);
  66  |     await this.page.getByTestId("workspace-save").click();
  67  |     await this.expectToast(`Workspace ${name} criado.`);
  68  |     await expect(this.title).toHaveText(name);
  69  |     await waitForLiveView(this.page);
  70  |   }
  71  | 
  72  |   workspace(slug: string): Locator {
  73  |     return this.page.getByTestId(`workspace-${slug}`);
  74  |   }
  75  | 
  76  |   async openWorkspace(slug: string) {
  77  |     await this.gotoWorkspaces();
  78  |     await this.workspace(slug).click();
  79  |     await waitForLiveView(this.page);
  80  |   }
  81  | 
  82  |   /** On a workspace page: renames it and returns to the list. */
  83  |   async editWorkspace(name: string, slug: string) {
  84  |     await this.page.getByTestId("edit-workspace").click();
  85  |     await this.page.getByTestId("workspace-name").fill(name);
  86  |     await this.page.getByTestId("workspace-slug").fill(slug);
  87  |     await this.page.getByTestId("workspace-save").click();
  88  |     await this.expectToast(`Workspace ${name} atualizado.`);
  89  |   }
  90  | 
  91  |   /** On a workspace page: creates a user straight into it. */
  92  |   async createMember(name: string, email: string, password: string) {
  93  |     await this.page.getByTestId("new-member-name").fill(name);
  94  |     await this.page.getByTestId("new-member-email").fill(email);
  95  |     await this.page.getByTestId("new-member-password").fill(password);
  96  |     await this.page.getByTestId("new-member-submit").click();
  97  |     await this.expectToast(`${name} criado e adicionado ao workspace.`);
  98  |   }
  99  | 
  100 |   /** On a workspace page: adds a user who already exists. */
  101 |   async addExistingMember(email: string) {
  102 |     await pickComboOption(this.page.getByTestId("add-existing-user"), email);
  103 |     await this.page.getByTestId("add-existing-submit").click();
  104 |     await this.expectToast(/agora faz parte de/);
  105 |   }
  106 | 
  107 |   member(email: string): Locator {
  108 |     return this.page.getByTestId(`member-${email}`);
  109 |   }
  110 | 
  111 |   async removeMember(email: string) {
  112 |     await this.page.getByTestId(`member-remove-${email}`).click();
  113 |     await this.expectToast(/saiu de/);
  114 |   }
  115 | 
  116 |   // ── Users ─────────────────────────────────────────────────────────────────
  117 | 
  118 |   async gotoUsers() {
  119 |     await this.page.getByTestId("sidebar-users").click();
  120 |     await expect(this.title).toHaveText("Usuários");
  121 |   }
  122 | 
  123 |   /** Creates a user outside any workspace and lands on their page. */
  124 |   async createUser(name: string, email: string, password: string) {
  125 |     await this.gotoUsers();
  126 |     await this.page.getByTestId("new-user").click();
  127 |     await this.page.getByTestId("user-form-name").fill(name);
  128 |     await this.page.getByTestId("user-form-email").fill(email);
  129 |     await this.page.getByTestId("user-form-password").fill(password);
```