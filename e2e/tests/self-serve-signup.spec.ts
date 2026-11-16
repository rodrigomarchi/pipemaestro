/**
 * @section Self-serve sign-up
 * @flow A [done] From the landing to the plans, sign-up, the first workspace and the lesson's
 *   three steps; finishing it opens the Free beta board, and signing in again skips the lesson
 * @flow B [done] Skipping the lesson on its first step is for good
 * @flow C [done] A taken e-mail is pointed out on the form, which keeps what was typed
 */
import { expect, test } from "@playwright/test";
import { uniqueSuffix, userPassword } from "../helpers/env";
import { shot } from "../helpers/screenshots";
import { AppPage } from "../pages/AppPage";
import { SignupPage } from "../pages/SignupPage";

test.describe("Self-serve sign-up", () => {
  test("from the landing to the board of a new workspace", async ({ page }) => {
    const suffix = uniqueSuffix();
    const person = { name: `Bia ${suffix}`, email: `bia-${suffix}@e2e.test` };
    const workspace = { name: `Time ${suffix}`, slug: `time-${suffix}` };
    const signup = new SignupPage(page);
    const app = new AppPage(page);

    await signup.fromLanding();
    await shot(page, "pricing");

    await page.setViewportSize({ width: 390, height: 844 });
    await shot(page, "pricing-phone");
    await page.setViewportSize({ width: 1280, height: 800 });

    await signup.startFree();
    await shot(page, "signup");
    await signup.fillSignUp(person.name, person.email, userPassword);
    await signup.submitSignUp();

    await expect(app.toasts).toContainText("Conta criada! Agora dê um nome ao seu workspace.");
    await shot(page, "workspace-new");
    await signup.createWorkspace(workspace.name);

    await expect(page).toHaveURL(`/w/${workspace.slug}/onboarding`);
    await signup.expectLessonStep(1);
    await shot(page, "lesson-step-1");
    await signup.lessonNext(2);
    await shot(page, "lesson-step-2");
    await signup.lessonNext(3);
    await shot(page, "lesson-step-3");
    await signup.finishLesson();

    await app.expectBoard(workspace.name);
    await app.expectPlanBadge("Free · BETA");
    await shot(page, "board-free-beta");

    await app.signOut();
    await app.signIn(person.email, userPassword);
    await app.expectBoard(workspace.name);
  });

  test("skipping the lesson is for good", async ({ page }) => {
    const suffix = uniqueSuffix();
    const workspace = { name: `Pula ${suffix}`, slug: `pula-${suffix}` };
    const signup = new SignupPage(page);
    const app = new AppPage(page);

    await signup.gotoSignUp();
    await signup.fillSignUp(`Caio ${suffix}`, `caio-${suffix}@e2e.test`, userPassword);
    await signup.submitSignUp();
    await signup.createWorkspace(workspace.name);

    await signup.expectLessonStep(1);
    await signup.skipLesson();
    await app.expectBoard(workspace.name);

    await page.goto(`/w/${workspace.slug}`);
    await app.expectBoard(workspace.name);
  });

  test("a taken e-mail is pointed out on the form", async ({ page }) => {
    const suffix = uniqueSuffix();
    const email = `dupla-${suffix}@e2e.test`;
    const signup = new SignupPage(page);
    const app = new AppPage(page);

    await signup.gotoSignUp();
    await signup.fillSignUp(`Dora ${suffix}`, email, userPassword);
    await signup.submitSignUp();
    await signup.createWorkspace(`Dora ${suffix}`);
    await signup.expectLessonStep(1);
    await signup.skipLesson();
    await app.signOut();

    await signup.gotoSignUp();
    await signup.fillSignUp(`Outra ${suffix}`, email, userPassword);
    await signup.submitSignUp();

    await expect(page.getByTestId("signup-form")).toContainText("já está em uso");
    await expect(page.getByTestId("signup-email")).toHaveValue(email);
    await shot(page, "signup-email-taken");
  });
});
