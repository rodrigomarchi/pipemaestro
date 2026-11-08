/**
 * @section Tarefas e pipelines
 * @flow A [done] A member creates the ready-made pipelines and edits one: its version goes up
 * @flow B [done] A task runs the 6 stages of "Correção de bug" on a real runner, in a git worktree of the chosen directory, each stage writing its artifact, until it succeeds
 * @flow C [done] A stage the agent blocks waits for a decision; the member retries it with instructions and the task succeeds
 * @flow E [done] Each stage shows the files it changed in the worktree, and the task the files changed so far
 * @flow F [done] A paused task shows in the Decisions page and the menu's counter, and every task on the board, by state
 * @flow G [done] A project of a directory sets up the worktree with its command, and a stage's gate runs the project's test command after the agent
 * @flow D [done] The runner prepares a new worktree with the directory's dependencies, and removes it when the member asks, keeping the branch
 * @flow H [done] A finished stage's steps are strips of icons that open their panels, filtered by kind (thinking shows only the model's thoughts)
 * @flow I [done] Usage breaks the cost down by origin and by stage (with the average wait and gate time), narrows to one pipeline, and goes back 90 days
 * @flow J [done] A task that ended takes a prompt: the correction runs as a new stage in its worktree, made again after it was removed
 * @flow K [done] A stage is redone from its modal with instructions, which reach the agent
 * @flow L [done] A running stage is interrupted: the task waits for a decision instead of ending
 * @flow M [done] With a delivery, the platform checks each stage after the agent (it commits; the last stage takes the artifacts out of the branch), and a check that fails goes back to the agent with the reason
 * @flow N [done] The board opens on its overview and splits into tabs (overview, tasks, decisions, activity, runners), each its own URL that survives a reload, with the runners counted online/total on their tab
 */
import { existsSync, readFileSync } from "node:fs";
import { execFileSync } from "node:child_process";
import { join } from "node:path";
import { expect, test } from "@playwright/test";
import { bootstrapOperator, uniqueSuffix, userPassword } from "../helpers/env";
import { RunnerProcess } from "../helpers/runnerProcess";
import { waitForLiveView } from "../helpers/liveView";
import { expectFitsPhone } from "../helpers/phone";
import { shot } from "../helpers/screenshots";
import { AppPage, boardTabs } from "../pages/AppPage";
import { BackofficePage } from "../pages/BackofficePage";
import { Timeline } from "../pages/JobsPage";
import { PipelinesPage } from "../pages/PipelinesPage";
import { ProjectsPage } from "../pages/ProjectsPage";
import { RunnersPage } from "../pages/RunnersPage";
import { TasksPage } from "../pages/TasksPage";
import { clickPageAction } from "../helpers/pageActions";

/** A git command in `dir`, its output trimmed. */
function git(dir: string, ...args: string[]): string {
  return execFileSync("git", ["-C", dir, ...args], { encoding: "utf8" }).trim();
}

test.describe("Task pipeline", () => {
  // Real CLI processes: the first one may compile the runner app.
  test.setTimeout(240_000);

  let runner: RunnerProcess;

  test.afterEach(() => runner?.cleanup());

  test("runs a task through the pipeline's stages on a real runner", async ({ page, browser }) => {
    const suffix = uniqueSuffix();
    const workspace = { name: `Pipelines ${suffix}`, slug: `pipelines-${suffix}` };
    const user = { name: `Paula ${suffix}`, email: `paula-${suffix}@e2e.test` };
    const runnerName = `pipe-${suffix}`;

    const backoffice = new BackofficePage(page);
    await backoffice.signInExpectingSuccess(bootstrapOperator.email, bootstrapOperator.password);
    await backoffice.createWorkspace(workspace.name);
    await backoffice.createMember(user.name, user.email, userPassword);

    const context = await browser.newContext();
    const app = new AppPage(await context.newPage());
    await app.signIn(user.email, userPassword);
    await app.expectBoard(workspace.name);

    runner = new RunnerProcess();
    const root = runner.createCodeRoot();
    runner.start("runner.login", ["--url", app.page.url().replace(/\/w\/.*$/, "")]);
    const [, code] = await runner.waitFor(/digite o código:\s+([A-Z]{4}-[A-Z]{4})/);
    await new RunnersPage(app.page).approve(code, runnerName);
    expect(await runner.waitForExit()).toBe(0);

    runner.start("runner.start", ["--root", root]);
    await runner.waitFor(/Online como/);

    const projects = new ProjectsPage(app.page);
    await projects.open(workspace.slug);
    await projects.create({ name: "App", runner: runnerName, directory: "app" });
    await projects.create({ name: "Notas", runner: runnerName, directory: "notas" });

    // Flow A: ready-made pipelines, one edited.
    const pipelines = new PipelinesPage(app.page);
    await pipelines.open(workspace.slug);
    await pipelines.createDefaults();
    await expect(pipelines.version("Prompt único")).toHaveText("v1");
    await shot(app.page, "pipelines");

    await pipelines.edit("Prompt único");

    // The prompt editor: the toolbar formats, the menu inserts a variable and
    // the preview renders the Markdown.
    await pipelines.stagePrompt(0).fill("## Objetivo\n\n");
    await pipelines.stagePromptAction(0, "bold").click();
    await pipelines.insertVariable(0, "tarefa.titulo");
    // Bold leaves its placeholder selected, and the variable takes its place.
    await expect(pipelines.stagePrompt(0)).toHaveValue("## Objetivo\n\n**{{tarefa.titulo}}**");
    await pipelines.previewPrompt(0);
    // Rendered: the text shows without its Markdown marks.
    await expect(pipelines.stagePromptPreview(0)).toContainText("Objetivo");
    await expect(pipelines.stagePromptPreview(0)).toContainText("{{tarefa.titulo}}");
    await expect(pipelines.stagePromptPreview(0)).not.toContainText("##");
    await expect(pipelines.stagePromptPreview(0)).not.toContainText("**");
    await shot(app.page, "pipeline-prompt-preview");
    await pipelines.writePrompt(0);

    await pipelines.stagePrompt(0).fill("{{tarefa.descricao}}\n\nRegistre no artefato o que foi feito.");
    await pipelines.stageGates(0).fill("{{projeto.teste}}");
    // Flow M: commits by the agent, checked by the platform, as the form says.
    await app.page.getByTestId("pipeline-delivery").selectOption("commit");
    await expect(app.page.getByTestId("pipeline-platform-checks")).toContainText("Nada ficou sem commit");
    await shot(app.page, "pipeline-form");
    await pipelines.save();
    await expect(pipelines.version("Prompt único")).toHaveText("v2");

    // Flow B: the 6 stages of "Correção de bug" in a worktree of `app`.
    const tasks = new TasksPage(app.page);
    await tasks.open(workspace.slug);
    const bugId = await tasks.create({
      title: "Botão de login não responde",
      prompt: "Ao clicar em Entrar nada acontece.",
      pipeline: "Correção de bug",
      project: "App",
      shot: "task-form",
    });

    await expect(tasks.status).toHaveText("Concluída", { timeout: 60_000 });
    await tasks.openStage("pr");
    await expect(tasks.stageRunStatus("pr", 1)).toHaveText("Aprovada no gate");
    await tasks.closeStage();
    await expect(app.page.getByTestId("task-branch")).toContainText("cp/botao-de-login-nao-responde-");

    const worktree = join(runner.workdir, "worktrees", bugId);
    await expect(app.page.getByTestId("task-worktree")).toHaveText(worktree);
    for (const artifact of ["01-triagem", "03-reproducao", "06-pr"]) {
      expect(existsSync(join(worktree, ".control-plane", bugId, `${artifact}.md`))).toBe(true);
    }
    expect(existsSync(join(root, "app", "fake-claude.txt"))).toBe(false);

    // Flow E: what each stage changed (its artifact and the file the fake agent writes).
    await tasks.openStage("triagem");
    await expect(app.page.getByTestId("stage-run-changes-triagem-1")).toContainText("2 arquivos alterados");
    await expect(app.page.getByTestId("task-files")).toContainText("06-pr.md");
    await expect(app.page.getByTestId("task-files")).toContainText("fake-claude.txt");
    // The artifact's code block is highlighted in the browser.
    await expect(app.page.getByTestId("stage-run-artifact-triagem-1")).toHaveAttribute("data-highlighted", "true");
    await tasks.openDetails("triagem", 1);
    await app.page.getByTestId("stage-run-changes-summary-triagem-1").click();
    await expect(app.page.getByTestId("stage-run-patch-triagem-1")).toContainText("+# Artefato do fake_claude");
    await shot(app.page, "task-succeeded");
    await expectFitsPhone(app.page, "task-succeeded");
    // The request, the files and the decisions each have a tab of their own.
    await tasks.closeStage();
    await app.page.getByTestId("task-tab-pedido").click();
    await expect(app.page.getByTestId("task-prompt-text")).toBeVisible();
    await shot(app.page, "task-request");
    await app.page.getByTestId("task-tab-arquivos").click();
    await expect(app.page.getByTestId("task-files")).toBeVisible();
    await app.page.getByTestId("task-tab-etapas").click();
    // The pipeline, vertical: every stage passed, each a link to its panel.
    await expect(tasks.stageNode("triagem")).toHaveAttribute("data-state", "passed");
    await expect(tasks.stageNode("pr")).toHaveAttribute("data-state", "passed");
    await expect(tasks.stageNode("investigacao")).toHaveAttribute("href", /etapa=investigacao/);
    await tasks.openStage("triagem");

    // Flow H: a finished stage's steps; an icon opens its panel, another
    // switches, the same closes; the reasoning filter keeps only thinking.
    const steps = new Timeline(await tasks.openSteps("triagem", 1));
    await expect(steps.icons()).toHaveCount(4);
    await steps.toggle(3);
    await expect(steps.panel(3)).toBeVisible();
    await steps.toggle(1);
    await expect(steps.panel(1)).toBeVisible();
    await expect(steps.panel(3)).toBeHidden();
    await shot(steps.scope, "task-steps-panel-open");
    await steps.toggle(1);
    await expect(steps.panel(1)).toBeHidden();

    await tasks.filterSteps("triagem", 1, "thinking");
    await expect(steps.icons()).toHaveCount(1);
    await expect(steps.icon(2)).toHaveAttribute("data-type", "thinking");
    await expect(steps.texts()).toHaveCount(0);
    await steps.toggle(2);
    await expect(steps.panel(2)).toBeVisible();
    await expect(steps.panel(2)).toContainText("não mostra o raciocínio");
    await shot(steps.scope, "task-steps-thinking");
    await tasks.filterSteps("triagem", 1, "all");

    // Flow D: the worktree was prepared, and goes when asked.
    await expect(app.page.getByTestId("stage-run-setup-triagem-1")).toContainText("copiado: deps");
    expect(readFileSync(join(worktree, "deps", "jason", "mix.exs"), "utf8")).toBe("jason\n");
    await tasks.removeWorktree();
    await expect(tasks.worktreeState).toHaveText("Removido do runner.");
    expect(existsSync(worktree)).toBe(false);
    await shot(app.page, "task-worktree-removed");

    // Flow J: a correction after the task ended, in a worktree made again.
    await expect(app.page.getByTestId("task-correct")).toBeVisible();
    await tasks.correct("Registre também a correção pedida.");
    await expect(tasks.status).toHaveText("Concluída");
    await tasks.openStage("correcao-1");
    await expect(tasks.stageRunStatus("correcao-1", 1)).toHaveText("Aprovada no gate");
    await expect(tasks.stageRun("correcao-1", 1)).toContainText("Registre também a correção pedida.");
    await expect(app.page.getByTestId("task-decisions")).toContainText("Corrigir");
    expect(existsSync(join(worktree, ".control-plane", bugId, "07-correcao-1.md"))).toBe(true);
    await shot(app.page, "task-corrected");

    // Flow C: a blocked stage, retried with instructions.
    await tasks.backToList();
    const blockedId = await tasks.create({
      title: "Erro intermitente",
      prompt: "Às vezes a tela fica branca. [bloqueio]",
      pipeline: "Prompt único",
      project: "Notas",
    });

    await expect(tasks.status).toHaveText("Aguardando decisão");
    await expect(tasks.decisionReason).toContainText("Preciso saber qual navegador");
    await expect(tasks.stageNode("executar")).toHaveAttribute("data-state", "awaiting");
    await shot(app.page, "task-awaiting-decision");

    // The board's tasks tab shows where each task is, a dot per stage.
    await app.openBoard(workspace.slug, "tarefas");
    await expect(
      app.page.getByTestId(`board-task-progress-${blockedId}`).getByTestId("diagram-dot-0"),
    ).toHaveAttribute("data-state", "awaiting");
    await shot(app.page, "board-progress");

    // Flow F: the Decisions page lists it, the menu counts it.
    await expect(app.page.getByTestId("sidebar-decisions")).toContainText("1");
    await app.page.getByTestId("sidebar-decisions").click();
    await expect(app.page.getByTestId(`decision-${blockedId}`)).toContainText("Preciso saber qual navegador");
    await expect(
      app.page.getByTestId(`decision-progress-${blockedId}`).getByTestId("diagram-dot-0"),
    ).toHaveAttribute("data-state", "awaiting");
    await shot(app.page, "decisions");
    await expectFitsPhone(app.page, "decisions");
    await app.page.getByTestId(`decision-link-${blockedId}`).click();
    await expect(tasks.status).toHaveText("Aguardando decisão");
    await waitForLiveView(app.page);

    await tasks.retryWith("[desbloqueio] Acontece no Safari 17.");
    await expect(tasks.status).toHaveText("Concluída");
    await expect(tasks.stageRun("executar", 2)).toContainText("Acontece no Safari 17.");
    expect(readFileSync(join(root, "notas", "fake-claude.txt"), "utf8")).toContain("Safari 17");
    await shot(app.page, "task-decided");

    // Flow K: redo with instructions, from the stage's modal.
    await app.page.getByTestId("stage-redo-executar").click();
    await expect(app.page.getByTestId("stage-redo-modal")).toBeVisible();
    await shot(app.page, "task-redo-modal");
    await app.page.getByTestId("stage-redo-text").fill("[desbloqueio] Agora no Firefox.");
    await app.page.getByTestId("stage-redo-submit").click();
    await expect(tasks.status).toHaveText("Concluída");
    await expect(tasks.stageRun("executar", 3)).toContainText("Agora no Firefox.");

    // Flow L: a slow stage interrupted waits for a decision; canceled after.
    await tasks.backToList();
    await tasks.create({
      title: "Demorada",
      prompt: "Leva tempo. [lento]",
      pipeline: "Prompt único",
      project: "Notas",
    });
    await tasks.openStage("executar");
    await expect(tasks.stageRunStatus("executar", 1)).toHaveText("Executando");
    await tasks.interrupt();
    await expect(tasks.status).toHaveText("Aguardando decisão");
    await expect(tasks.decisionReason).toContainText("foi interrompida");
    await shot(app.page, "task-interrupted");
    await clickPageAction(app.page, "task-cancel");
    await expect(tasks.status).toHaveText("Cancelada");
    await expect(app.page.getByTestId("task-correct")).toBeVisible();

    // Flow G: a project for `app`, its setup and its test command as a gate.
    await projects.open(workspace.slug);
    await projects.configure("app", {
      setup: "echo pronto > setup.txt",
      test: "test -f fake-claude.txt",
      shot: "project-form",
    });
    await shot(app.page, "projects");

    await tasks.open(workspace.slug);
    const gatedId = await tasks.create({
      title: "Com gate",
      prompt: "Faça e registre.",
      pipeline: "Prompt único",
      project: "App",
    });
    await expect(tasks.status).toHaveText("Concluída");
    await tasks.openStage("executar");
    await expect(app.page.getByTestId("stage-run-gate-executar-1-0")).toHaveAttribute("data-passed", "true");
    await expect(app.page.getByTestId("stage-run-gates-executar-1")).toContainText("test -f fake-claude.txt");
    await expect(app.page.getByTestId("stage-run-setup-executar-1")).toContainText("echo pronto > setup.txt");
    expect(readFileSync(join(runner.workdir, "worktrees", gatedId, "setup.txt"), "utf8")).toBe("pronto\n");
    // Flow M: the platform's checks ran before the gate, and the last stage
    // took the artifacts out of the branch, keeping them on disk.
    await expect(app.page.getByTestId("stage-run-gate-platform-executar-1-0")).toHaveText("plataforma");
    const gatedTree = join(runner.workdir, "worktrees", gatedId);
    expect(git(gatedTree, "log", "-1", "--format=%s")).toBe("fake_claude: etapa");
    expect(git(gatedTree, "ls-tree", "-r", "--name-only", "HEAD", "--", ".control-plane")).toBe("");
    expect(existsSync(join(gatedTree, ".control-plane", gatedId, "01-executar.md"))).toBe(true);
    await shot(app.page, "task-gated");

    // Flow M: something left uncommitted fails the check; the agent fixes it.
    await tasks.backToList();
    await tasks.create({
      title: "Esqueceu um arquivo",
      prompt: "Faça e registre. [sujo]",
      pipeline: "Prompt único",
      project: "App",
    });
    // One attempt in this pipeline: the failed check waits for a decision.
    await expect(tasks.status).toHaveText("Aguardando decisão");
    await tasks.openDecision();
    await expect(tasks.stageRunStatus("executar", 1)).toHaveText("Falhou");
    await expect(tasks.decisionReason).toContainText("sujo.txt");
    await expect(app.page.getByTestId("stage-run-gates-executar-1")).toContainText("sujo.txt");
    await shot(app.page, "task-check-failed");
    await waitForLiveView(app.page);
    await tasks.retryWith("Corrija o que a plataforma apontou.");
    await expect(tasks.status).toHaveText("Concluída");
    await expect(tasks.stageRunStatus("executar", 2)).toHaveText("Aprovada no gate");

    await tasks.backToList();
    await expect(tasks.listStatus(bugId)).toHaveText("Concluída");
    await expect(tasks.listStatus(blockedId)).toHaveText("Concluída");
    await shot(app.page, "tasks-list");

    await app.page.getByTestId("sidebar-board").click();
    await app.expectBoardTab("visao");
    await expect(app.page.getByTestId("board-stat-succeeded")).toHaveText("4");
    await expect(app.page.getByTestId("board-column-done")).toHaveCount(0);
    await app.openBoardTab("tarefas");
    await expect(app.page.getByTestId(`board-task-${bugId}`)).toBeVisible();
    await expect(app.page.getByTestId("board-column-done")).toContainText("Erro intermitente");
    await expect(app.page.getByTestId("board-stat-succeeded")).toHaveCount(0);
    await shot(app.page, "board");

    // Flow N: each tab of the board, the runners counted online/total, at full and narrow width.
    await expect(app.boardTabCount("executores")).toContainText("/1");
    for (const tab of boardTabs) {
      await app.openBoardTab(tab);
      await shot(app.page, `board-${tab}`);
    }
    await app.page.reload();
    await app.expectBoardTab("executores");
    const viewport = app.page.viewportSize();
    await app.page.setViewportSize({ width: 390, height: 844 });
    await expect(app.boardTab("visao")).toBeVisible();
    await shot(app.page, "board-tabs-narrow");
    if (viewport) await app.page.setViewportSize(viewport);

    await app.page.getByTestId("sidebar-usage").click();
    await expect(app.page.getByTestId("usage-by-runner")).toContainText(runnerName);
    await expect(app.page.getByTestId("usage-agent-cache-hit")).toHaveText("91%");
    await expect(app.page.getByTestId("usage-agent-tool-errors-Write")).toHaveText("0");
    await shot(app.page, "usage");
    await app.page.getByTestId("usage-tab-agente").click();
    await expect(app.page.getByTestId("usage-agent-cache-hit")).toBeVisible();
    await shot(app.page, "usage-agent");

    // Flow I: by origin, one pipeline, 90 days.
    await expect(app.page.getByTestId("usage-by-origin-stage")).toContainText("Etapas de pipeline");
    await expect(app.page.getByTestId("usage-stage-queue-executar")).not.toHaveText("—");
    await app.page.getByTestId("usage-pipeline").selectOption("Correção de bug");
    await expect(app.page.getByTestId("usage-period-label")).toContainText("Correção de bug");
    await app.page.getByTestId("usage-tab-etapas").click();
    await expect(app.page.getByTestId("usage-panel-etapas")).toBeVisible();
    // The pipeline, stage by stage, with what each one spent.
    await expect(app.page.getByTestId("usage-pipeline-diagram").getByTestId("diagram-metrics-0")).toContainText("US$");
    await shot(app.page, "usage-pipeline-diagram");
    await app.page.getByTestId("usage-period").selectOption("90");
    await expect(app.page.getByTestId("usage-period-label")).toContainText("90 dias");
    await expect(app.page.getByTestId("usage-period-label")).toContainText("Correção de bug");
    await shot(app.page, "usage-filtered");

    await context.close();
  });
});
