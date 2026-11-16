import { expect, type Page } from "@playwright/test";
import { waitForLiveView } from "../helpers/liveView";

/**
 * Self-serve sign-up (ADR 0058): the plans page, the sign-up form, the first
 * workspace and the getting-started lesson. Every element is reached by its
 * `data-testid`.
 */
export class SignupPage {
  readonly page: Page;

  constructor(page: Page) {
    this.page = page;
  }

  /** From the landing's hero to the plans page. */
  async fromLanding() {
    await this.page.goto("/");
    await this.page.getByTestId("hero-signup").click();
    await this.expectPricing();
  }

  async expectPricing() {
    await expect(this.page.getByTestId("plan-card-free")).toBeVisible();
    await expect(this.page.getByTestId("plan-badge-beta")).toHaveText("BETA");
  }

  async startFree() {
    await this.page.getByTestId("plan-start-free").click();
    await expect(this.page.getByTestId("signup-email")).toBeVisible();
    await waitForLiveView(this.page);
  }

  async gotoSignUp() {
    await this.page.goto("/signup");
    await waitForLiveView(this.page);
  }

  async fillSignUp(name: string, email: string, password: string) {
    await this.page.getByTestId("signup-name").fill(name);
    await this.page.getByTestId("signup-email").fill(email);
    await this.page.getByTestId("signup-password").fill(password);
  }

  async submitSignUp() {
    await this.page.getByTestId("signup-submit").click();
  }

  /** Creates the first workspace, from the form the sign-up leads to. */
  async createWorkspace(name: string) {
    await expect(this.page.getByTestId("workspace-new-stepper")).toBeVisible();
    await waitForLiveView(this.page);
    await this.page.getByTestId("workspace-new-name").fill(name);
    await this.page.getByTestId("workspace-new-submit").click();
  }

  async expectLessonStep(step: number) {
    await expect(this.page.getByTestId(`onboarding-step-${step}`)).toBeVisible();
    await waitForLiveView(this.page);
  }

  async lessonNext(step: number) {
    await this.page.getByTestId("onboarding-next").click();
    await this.expectLessonStep(step);
  }

  async skipLesson() {
    await this.page.getByTestId("onboarding-skip").click();
  }

  async finishLesson() {
    await this.page.getByTestId("onboarding-finish").click();
  }
}
