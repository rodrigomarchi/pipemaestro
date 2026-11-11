import { expect, type Locator, type Page } from "@playwright/test";
import { acceptConfirms, waitForLiveView } from "../helpers/liveView";
import { selectProject } from "../helpers/projectSelect";
import { shot } from "../helpers/screenshots";
import { clickPageAction } from "../helpers/pageActions";

/** Tasks: the list, the new-task form and one task's stages and decisions. */
export class TasksPage {
  readonly page: Page;
  readonly status: Locator;
  /** Why the task waits: the banner over the pipeline, with the reason. */
  readonly decisionReason: Locator;

  constructor(page: Page) {
    this.page = page;
    this.status = page.getByTestId("task-status");
    this.decisionReason = page.getByTestId("task-decision-banner");
    acceptConfirms(page);
  }

  async open(workspaceSlug: string) {
    await this.page.goto(`/w/${workspaceSlug}/tasks`);
    await waitForLiveView(this.page);
  }

  /** Starts a task in the project named `project`, waits on its page and returns the task's id. */
  async create(task: {
    title: string;
    prompt: string;
    pipeline: string;
    project: string;
    /** Captures the filled form under this name (E2E_SHOTS). */
    shot?: string;
    /** Runs on the filled form, before submitting. */
    onFilled?: () => Promise<void>;
  }): Promise<string> {
    await clickPageAction(this.page, "new-task");
    await this.page.getByTestId("task-title").fill(task.title);
    await this.page.getByTestId("task-prompt").fill(task.prompt);
    await this.page.getByTestId("task-pipeline").selectOption({ label: task.pipeline });
    // The pipeline chosen, small, under the select.
    await expect(this.page.getByTestId("task-pipeline-preview")).toBeVisible();
    await selectProject(this.page.getByTestId("task-project"), task.project);
    if (task.shot) await shot(this.page, task.shot);
    if (task.onFilled) await task.onFilled();
    await this.page.getByTestId("task-submit").click();
    await expect(this.overview()).toBeVisible();
    await waitForLiveView(this.page);
    return new URL(this.page.url()).pathname.split("/").pop()!;
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

  /** The task's project (a link to it) and its snapshot, in the entry's "Projeto" tab. */
  get project(): Locator {
    return this.page.getByTestId("task-project");
  }

  stageRunStatus(key: string, attempt: number): Locator {
    return this.page.getByTestId(`stage-run-status-${key}-${attempt}`);
  }

  stageRun(key: string, attempt: number): Locator {
    return this.page.getByTestId(`stage-run-${key}-${attempt}`);
  }

  /**
   * The status of an attempt run again after a loss of its runner: the same
   * attempt, the `requeue`-th time (`-r1`, `-r2`...).
   */
  requeuedRunStatus(key: string, attempt: number, requeue: number): Locator {
    return this.page.getByTestId(`stage-run-status-${key}-${attempt}-r${requeue}`);
  }

  /** Why an attempt was lost (its runner restarted or was updated in the middle of it). */
  stageRunLost(key: string, attempt: number): Locator {
    return this.page.getByTestId(`stage-run-lost-${key}-${attempt}`);
  }

  /**
   * Opens a tab of an attempt: "resultado" (where it opens, unless a check
   * refused it), "verificacao" (gates, commit, changes), "passos" (the agent's
   * steps) or "contexto" (what the agent was given).
   */
  async openAttemptTab(key: string, attempt: number, tab: string) {
    await this.page.getByTestId(`stage-run-${key}-${attempt}-tab-${tab}`).click();
    await expect(this.page.getByTestId(`stage-run-${key}-${attempt}-panel-${tab}`)).toBeVisible();
  }

  /** A finished attempt's steps, read when its "Passos" tab opens. */
  async openSteps(key: string, attempt: number): Promise<Locator> {
    await this.openAttemptTab(key, attempt, "passos");
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

  /**
   * Unfolds "Decidir sem responder" when the questionnaire keeps it folded,
   * opening the waiting stage's panel first.
   */
  async openManualDecision() {
    if (!(await this.page.getByTestId("decision-panel").isVisible())) await this.openDecision();
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

  /** The task's page: its pipeline, vertical, each place a link to its drawer. */
  overview(): Locator {
    return this.page.getByTestId("task-overview");
  }

  /**
   * A place of the pipeline that is not a stage: "entrada" (the request and
   * where it runs), "entrega" (the files changed and the branch), "fim" (the
   * cost and the files sent) or "corrigir" (a correction of a task that ended).
   */
  node(node: "entrada" | "entrega" | "fim" | "corrigir"): Locator {
    return this.page.getByTestId(node === "fim" ? "task-overview-end" : `task-node-${node}`);
  }

  /** The drawer of a place that is not a stage. */
  nodePanel(): Locator {
    return this.page.getByTestId("task-node-panel");
  }

  /** Opens a place's drawer, and one of its tabs when `tab` is given. */
  async openNode(node: "entrada" | "entrega" | "fim" | "corrigir", tab?: string) {
    await this.closePanelsIfOpen();
    await this.node(node).click();
    await expect(this.nodePanel()).toBeVisible();
    await expect(this.page).toHaveURL(new RegExp(`[?&]no=${node}(&|$)`));
    if (tab) {
      await this.page.getByTestId(`task-node-tab-${tab}`).click();
      await expect(this.page.getByTestId(`task-node-panel-${tab}`)).toBeVisible();
    }
  }

  /** A tab of the open place's drawer, with its counter in its name. */
  nodeTab(tab: string): Locator {
    return this.page.getByTestId(`task-node-tab-${tab}`);
  }

  /** Closes the place's drawer by its button; the place leaves the URL. */
  async closeNode() {
    await this.page.getByTestId("task-node-panel-close").click();
    await expect(this.nodePanel()).toBeHidden();
    await expect(this.page).not.toHaveURL(/[?&]no=/);
  }

  /** Closes whichever drawer is open, so the page behind it takes clicks. */
  async closePanelsIfOpen() {
    await this.closeStageIfOpen();
    if (await this.nodePanel().isVisible()) await this.closeNode();
  }

  /** A stage's node in the vertical pipeline, by its key. */
  stageNode(key: string): Locator {
    return this.page.getByTestId(`task-stage-${key}`);
  }

  /** The state badge of a stage's node. */
  stageNodeState(key: string): Locator {
    return this.page.getByTestId(`task-stage-state-${key}`);
  }

  /** The panel with one stage's details. */
  stagePanel(): Locator {
    return this.page.getByTestId("task-stage-panel");
  }

  /** Opens a stage's panel from its node; the stage goes to the URL. */
  async openStage(key: string) {
    await this.stageNode(key).click();
    await expect(this.stagePanel()).toBeVisible();
    await expect(this.page).toHaveURL(new RegExp(`[?&]etapa=${key}(&|$)`));
  }

  /** Closes the stage's panel by its button; the stage leaves the URL. */
  async closeStage() {
    await this.page.getByTestId("task-stage-panel-close").click();
    await this.expectStageClosed();
  }

  /** Closes the stage's panel, when one is open, so the page behind it takes clicks. */
  async closeStageIfOpen() {
    if (await this.stagePanel().isVisible()) await this.closeStage();
  }

  /** Closes the stage's panel with Escape. */
  async closeStageWithEscape() {
    await this.page.keyboard.press("Escape");
    await this.expectStageClosed();
  }

  async expectStageClosed() {
    await expect(this.stagePanel()).toBeHidden();
    await expect(this.page).not.toHaveURL(/[?&]etapa=/);
  }

  /** Picks one of the stage's attempts in its panel. */
  async selectAttempt(key: string, attempt: number) {
    await this.page.getByTestId(`task-stage-attempt-${key}-${attempt}`).click();
    await expect(this.stageRun(key, attempt)).toBeVisible();
  }

  /** The live timeline of the running stage, in its panel. */
  liveEvents(): Locator {
    return this.page.getByTestId("task-events");
  }

  /** A stage attempt's artifact, rendered. */
  stageRunArtifact(key: string, attempt: number): Locator {
    return this.page.getByTestId(`stage-run-artifact-${key}-${attempt}`);
  }

  /** The notice over the pipeline while the task waits for a decision. */
  decisionBanner(): Locator {
    return this.page.getByTestId("task-decision-banner");
  }

  /** "Decidir": opens the panel of the stage that waits. */
  async openDecision() {
    await this.page.getByTestId("task-decision-open").click();
    await expect(this.stagePanel()).toBeVisible();
    await expect(this.page.getByTestId("decision-panel")).toBeVisible();
  }

  /** Removes the finished task's worktree (the confirmation is accepted by `acceptConfirms`). */
  async removeWorktree() {
    await this.closePanelsIfOpen();
    await clickPageAction(this.page, "task-remove-worktree");
  }

  /**
   * "Corrigir com um prompt", the place after the end of a task that ended:
   * runs `prompt` as a new stage.
   */
  async correct(prompt: string) {
    await this.openNode("corrigir");
    await this.page.getByTestId("task-correct-text").fill(prompt);
    await this.page.getByTestId("task-correct-submit").click();
  }

  /**
   * Stops the running stage from its panel, open (the confirmation is
   * accepted by `acceptConfirms`), and closes it.
   */
  async interrupt() {
    await this.stagePanel().getByTestId("task-interrupt").click();
    await expect(this.page.getByTestId("decision-panel")).toBeVisible();
    await this.closeStage();
  }

  /** The worktree's state, in the entry's "Projeto" tab. */
  get worktreeState(): Locator {
    return this.page.getByTestId("task-worktree-state");
  }

  async backToList() {
    await this.closePanelsIfOpen();
    await this.page.getByTestId("back-to-tasks").click();
    await expect(this.page.getByTestId("page-title")).toHaveText("Tarefas");
  }

  listStatus(taskId: string): Locator {
    return this.page.getByTestId(`task-status-${taskId}`);
  }

  /** The files an attempt sent from the runner (`$CP_FILES_DIR`), beside its artifact. */
  stageRunFiles(key: string, attempt: number): Locator {
    return this.page.getByTestId(`stage-run-files-${key}-${attempt}`);
  }

  /** One of an attempt's files, by its path in the job's folder. */
  stageRunFile(key: string, attempt: number, path: string): Locator {
    return this.page.getByTestId(`stage-run-file-${key}-${attempt}-${path}`);
  }

  /** An image file's thumbnail (an `<img>`). */
  stageRunFileThumb(key: string, attempt: number, path: string): Locator {
    return this.page.getByTestId(`stage-run-file-thumb-${key}-${attempt}-${path}`);
  }

  /** The link that downloads one of an attempt's files. */
  stageRunFileDownload(key: string, attempt: number, path: string): Locator {
    return this.page.getByTestId(`stage-run-file-download-${key}-${attempt}-${path}`);
  }

  /** The warning that some of an attempt's files did not reach the platform. */
  stageRunFilesFailed(key: string, attempt: number): Locator {
    return this.page.getByTestId(`stage-run-files-failed-${key}-${attempt}`);
  }

  /** A file the retention emptied: its name and why, without a link. */
  stageRunFilePruned(key: string, attempt: number, path: string): Locator {
    return this.page.getByTestId(`stage-run-file-pruned-${key}-${attempt}-${path}`);
  }

  /** The warning that the workspace's quota refused some of an attempt's files. */
  stageRunFilesRefused(key: string, attempt: number): Locator {
    return this.page.getByTestId(`stage-run-files-refused-${key}-${attempt}`);
  }

  /** The notice, over a finished attempt's steps, that their content was removed. */
  stageRunEventsPruned(key: string, attempt: number): Locator {
    return this.page.getByTestId(`stage-run-events-pruned-${key}-${attempt}`);
  }

  /** A file the retention emptied, in the end's "Anexos" tab. */
  attachmentPruned(key: string, attempt: number, path: string): Locator {
    return this.page.getByTestId(`task-attachment-pruned-${key}-${attempt}-${path}`);
  }

  /** An attempt's group in the end's "Anexos" tab. */
  attachments(key: string, attempt: number): Locator {
    return this.page.getByTestId(`task-attachments-${key}-${attempt}`);
  }

  /** What the end's "Anexos" tab says while no attempt sent a file. */
  get noAttachments(): Locator {
    return this.page.getByTestId("task-no-attachments");
  }
}
