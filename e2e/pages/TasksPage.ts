import { expect, type Locator, type Page } from "@playwright/test";
import { acceptConfirms, waitForLiveView } from "../helpers/liveView";
import { shot } from "../helpers/screenshots";

/** Tasks: the list, the new-task form and one task's stages and decisions. */
export class TasksPage {
  readonly page: Page;
  readonly status: Locator;
  readonly decisionReason: Locator;

  constructor(page: Page) {
    this.page = page;
    this.status = page.getByTestId("task-status");
    this.decisionReason = page.getByTestId("decision-reason");
    acceptConfirms(page);
  }

  async open(workspaceSlug: string) {
    await this.page.goto(`/w/${workspaceSlug}/tasks`);
    await waitForLiveView(this.page);
  }

  /**
   * Starts a task and waits on its page; returns the task's id. The directory
   * select fills in once the runner is picked (selectOption waits for it).
   */
  async create(task: {
    title: string;
    prompt: string;
    pipeline: string;
    runner: string;
    directory: string;
    /** Captures the filled form under this name (E2E_SHOTS). */
    shot?: string;
  }): Promise<string> {
    await this.page.getByTestId("new-task").click();
    await this.page.getByTestId("task-title").fill(task.title);
    await this.page.getByTestId("task-prompt").fill(task.prompt);
    await this.page.getByTestId("task-pipeline").selectOption({ label: task.pipeline });
    await this.selectRunner(task.runner);
    await this.page.getByTestId("task-directory").selectOption(task.directory);
    if (task.shot) await shot(this.page, task.shot);
    await this.page.getByTestId("task-submit").click();
    await expect(this.page.getByTestId("task-prompt-text")).toHaveText(task.prompt);
    await waitForLiveView(this.page);
    return new URL(this.page.url()).pathname.split("/").pop()!;
  }

  /**
   * Each runner option reads "<name> (<how busy it is>)"; picks it by the name,
   * waiting for the runner to be listed (it shows once it is online).
   */
  private async selectRunner(name: string): Promise<void> {
    const select = this.page.getByTestId("task-runner");
    let value: string | undefined;

    await expect
      .poll(async () => {
        const options = await select.evaluate((el: HTMLSelectElement) =>
          Array.from(el.options).map((o) => ({ label: o.text, value: o.value })),
        );
        value = options.find((o) => o.label.startsWith(`${name} (`))?.value;
        return value;
      }, { message: `runner ${name} among the options` })
      .toBeTruthy();

    await select.selectOption(value!);
  }

  /** Opens one task's page. */
  async show(workspaceSlug: string, taskId: string) {
    await this.page.goto(`/w/${workspaceSlug}/tasks/${taskId}`);
    await expect(this.status).toBeVisible();
    await waitForLiveView(this.page);
  }

  /** The warning a running task shows while its runner is offline. */
  get runnerOffline(): Locator {
    return this.page.getByTestId("task-runner-offline");
  }

  stageRunStatus(key: string, attempt: number): Locator {
    return this.page.getByTestId(`stage-run-status-${key}-${attempt}`);
  }

  stageRun(key: string, attempt: number): Locator {
    return this.page.getByTestId(`stage-run-${key}-${attempt}`);
  }

  /** A finished attempt's steps, opened with their toggle. */
  async openSteps(key: string, attempt: number): Promise<Locator> {
    await this.page.getByTestId(`stage-run-steps-toggle-${key}-${attempt}`).click();
    const steps = this.page.getByTestId(`stage-run-steps-${key}-${attempt}`);
    await expect(steps).toBeVisible();
    return steps;
  }

  /** Picks a filter of a finished attempt's steps ("all", "agent", "tools", "thinking", "errors"). */
  async filterSteps(key: string, attempt: number, filter: string) {
    await this.page.getByTestId(`stage-run-steps-filter-${key}-${attempt}-${filter}`).click();
  }

  async retryWith(instructions: string) {
    await this.openManualDecision();
    await this.page.getByTestId("decision-instructions").fill(instructions);
    await this.page.getByTestId("decision-retry").click();
  }

  /** Unfolds "Decidir sem responder" when the questionnaire keeps it folded. */
  async openManualDecision() {
    const instructions = this.page.getByTestId("decision-instructions");
    if (await instructions.isVisible()) return;
    await this.page.getByTestId("decision-manual-toggle").click();
    await expect(instructions).toBeVisible();
  }

  /**
   * The decision questionnaire. On the Decisions page every id carries the
   * task's id as a suffix (`key`); on the task's page there is none.
   */
  questionnaire(key?: string): Locator {
    return this.page.getByTestId(this.questionnaireId("questionnaire", key));
  }

  questionnairePart(part: string, key?: string): Locator {
    return this.page.getByTestId(this.questionnaireId(`questionnaire-${part}`, key));
  }

  question(n: number, key?: string): Locator {
    return this.page.getByTestId(this.questionnaireId(`question-${n}`, key));
  }

  questionOption(n: number, m: number, key?: string): Locator {
    return this.page.getByTestId(this.questionnaireId(`question-${n}-option-${m}`, key));
  }

  /** Picks option `m` of question `n` (both from 0). */
  async answerQuestion(n: number, m: number, key?: string) {
    await this.questionOption(n, m, key).click();
  }

  /** Picks "Outro" in question `n` and writes `text` in it. */
  async fillOther(n: number, text: string, key?: string) {
    await this.page.getByTestId(this.questionnaireId(`question-${n}-other`, key)).click();
    await this.page.getByTestId(this.questionnaireId(`question-${n}-other-text`, key)).fill(text);
  }

  /** "Responder e continuar": opens the review step. */
  async submitAnswers(key?: string) {
    await expect(this.questionnairePart("submit", key)).toBeEnabled();
    await this.questionnairePart("submit", key).click();
    await expect(this.questionnairePart("review", key)).toBeVisible();
  }

  async confirmAnswers(key?: string) {
    await this.questionnairePart("confirm", key).click();
  }

  private questionnaireId(id: string, key?: string): string {
    return key ? `${id}-${key}` : id;
  }

  /** Removes the finished task's worktree (the confirmation is accepted by `acceptConfirms`). */
  async removeWorktree() {
    await this.page.getByTestId("task-remove-worktree").click();
  }

  get worktreeState(): Locator {
    return this.page.getByTestId("task-worktree-state");
  }

  async backToList() {
    await this.page.getByTestId("back-to-tasks").click();
    await expect(this.page.getByTestId("new-task")).toBeVisible();
  }

  listStatus(taskId: string): Locator {
    return this.page.getByTestId(`task-status-${taskId}`);
  }
}
