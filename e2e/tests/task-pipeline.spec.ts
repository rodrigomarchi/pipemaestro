/**
 * @section Tarefas e pipelines
 * @flow A [done] A member creates the ready-made pipelines and edits one: its version goes up
 * @flow B [done] A task runs the 6 stages of "Correção de bug" on a real runner, in a git worktree of the chosen directory, each stage writing its artifact, until it succeeds
 * @flow C [done] A stage the agent blocks waits for a decision; the member retries it with instructions and the task succeeds
 * @flow E [done] Each stage shows the files it changed in the worktree, and the task the files changed so far
 * @flow F [done] A paused task shows in the Decisions page and the menu's counter, and every task on the board, by state
 * @flow G [done] A project of a directory sets up the worktree with its command, and a stage's gate runs the project's test command after the agent
 * @flow D [done] The runner prepares a new worktree with the directory's dependencies, and removes it when the member asks, keeping the branch
 */
import { existsSync, readFileSync } from "node:fs";
import { join } from "node:path";
import { expect, test } from "@playwright/test";
import { bootstrapOperator, uniqueSuffix, userPassword } from "../helpers/env";
import { RunnerProcess } from "../helpers/runnerProcess";
import { waitForLiveView } from "../helpers/liveView";
import { shot } from "../helpers/screenshots";
import { AppPage } from "../pages/AppPage";
import { BackofficePage } from "../pages/BackofficePage";
import { PipelinesPage } from "../pages/PipelinesPage";
import { ProjectsPage } from "../pages/ProjectsPage";
import { RunnersPage } from "../pages/RunnersPage";
import { TasksPage } from "../pages/TasksPage";

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

    // Flow A: ready-made pipelines, one edited.
    const pipelines = new PipelinesPage(app.page);
    await pipelines.open(workspace.slug);
    await pipelines.createDefaults();
    await expect(pipelines.version("Prompt único")).toHaveText("v1");
    await shot(app.page, "pipelines");

    await pipelines.edit("Prompt único");
    await pipelines.stagePrompt(0).fill("{{tarefa.descricao}}\n\nRegistre no artefato o que foi feito.");
    await pipelines.stageGates(0).fill("{{projeto.teste}}");
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
      runner: runnerName,
      directory: "app",
    });

    await expect(tasks.status).toHaveText("Concluída", { timeout: 60_000 });
    await expect(tasks.stageRunStatus("pr", 1)).toHaveText("Aprovada no gate");
    await expect(app.page.getByTestId("task-branch")).toContainText("cp/botao-de-login-nao-responde-");

    const worktree = join(runner.workdir, "worktrees", bugId);
    await expect(app.page.getByTestId("task-worktree")).toHaveText(worktree);
    for (const artifact of ["01-triagem", "03-reproducao", "06-pr"]) {
      expect(existsSync(join(worktree, ".control-plane", bugId, `${artifact}.md`))).toBe(true);
    }
    expect(existsSync(join(root, "app", "fake-claude.txt"))).toBe(false);

    // Flow E: what each stage changed (its artifact and the file the fake agent writes).
    await expect(app.page.getByTestId("stage-run-changes-triagem-1")).toContainText("2 arquivos alterados");
    await expect(app.page.getByTestId("task-files")).toContainText("06-pr.md");
    await expect(app.page.getByTestId("task-files")).toContainText("fake-claude.txt");
    // The artifact's code block is highlighted in the browser.
    await expect(app.page.getByTestId("stage-run-artifact-triagem-1")).toHaveAttribute("data-highlighted", "true");
    await app.page.getByTestId("stage-run-changes-summary-triagem-1").click();
    await expect(app.page.getByTestId("stage-run-patch-triagem-1")).toContainText("+# Artefato do fake_claude");
    await shot(app.page, "task-succeeded");

    // Flow D: the worktree was prepared, and goes when asked.
    await expect(app.page.getByTestId("stage-run-setup-triagem-1")).toContainText("copiado: deps");
    expect(readFileSync(join(worktree, "deps", "jason", "mix.exs"), "utf8")).toBe("jason\n");
    await tasks.removeWorktree();
    await expect(tasks.worktreeState).toHaveText("Removido do runner.");
    expect(existsSync(worktree)).toBe(false);
    await shot(app.page, "task-worktree-removed");

    // Flow C: a blocked stage, retried with instructions.
    await tasks.backToList();
    const blockedId = await tasks.create({
      title: "Erro intermitente",
      prompt: "Às vezes a tela fica branca. [bloqueio]",
      pipeline: "Prompt único",
      runner: runnerName,
      directory: "notas",
    });

    await expect(tasks.status).toHaveText("Aguardando decisão");
    await expect(tasks.decisionReason).toContainText("Preciso saber qual navegador");
    await shot(app.page, "task-awaiting-decision");

    // Flow F: the Decisions page lists it, the menu counts it.
    await expect(app.page.getByTestId("sidebar-decisions")).toContainText("1");
    await app.page.getByTestId("sidebar-decisions").click();
    await expect(app.page.getByTestId(`decision-${blockedId}`)).toContainText("Preciso saber qual navegador");
    await shot(app.page, "decisions");
    await app.page.getByTestId(`decision-link-${blockedId}`).click();
    await expect(tasks.status).toHaveText("Aguardando decisão");
    await waitForLiveView(app.page);

    await tasks.retryWith("[desbloqueio] Acontece no Safari 17.");
    await expect(tasks.status).toHaveText("Concluída");
    await expect(tasks.stageRun("executar", 2)).toContainText("Acontece no Safari 17.");
    expect(readFileSync(join(root, "notas", "fake-claude.txt"), "utf8")).toContain("Safari 17");
    await shot(app.page, "task-decided");

    // Flow G: a project for `app`, its setup and its test command as a gate.
    const projects = new ProjectsPage(app.page);
    await projects.open(workspace.slug);
    await projects.create({
      name: "App",
      directory: "app",
      setup: "echo pronto > setup.txt",
      test: "test -f fake-claude.txt",
    });
    await shot(app.page, "projects");

    await tasks.open(workspace.slug);
    const gatedId = await tasks.create({
      title: "Com gate",
      prompt: "Faça e registre.",
      pipeline: "Prompt único",
      runner: runnerName,
      directory: "app",
    });
    await expect(tasks.status).toHaveText("Concluída");
    await expect(app.page.getByTestId("stage-run-gate-executar-1-0")).toHaveAttribute("data-passed", "true");
    await expect(app.page.getByTestId("stage-run-gates-executar-1")).toContainText("test -f fake-claude.txt");
    await expect(app.page.getByTestId("stage-run-setup-executar-1")).toContainText("echo pronto > setup.txt");
    expect(readFileSync(join(runner.workdir, "worktrees", gatedId, "setup.txt"), "utf8")).toBe("pronto\n");
    await shot(app.page, "task-gated");

    await tasks.backToList();
    await expect(tasks.listStatus(bugId)).toHaveText("Concluída");
    await expect(tasks.listStatus(blockedId)).toHaveText("Concluída");
    await shot(app.page, "tasks-list");

    await app.page.getByTestId("sidebar-board").click();
    await expect(app.page.getByTestId(`board-task-${bugId}`)).toBeVisible();
    await expect(app.page.getByTestId("board-column-done")).toContainText("Erro intermitente");
    await expect(app.page.getByTestId("board-stat-succeeded")).toHaveText("3");
    await shot(app.page, "board");

    await app.page.getByTestId("sidebar-usage").click();
    await expect(app.page.getByTestId("usage-by-runner")).toContainText(runnerName);
    await expect(app.page.getByTestId("usage-agent-cache-hit")).toHaveText("91%");
    await expect(app.page.getByTestId("usage-agent-tool-errors-Write")).toHaveText("0");
    await shot(app.page, "usage");

    await context.close();
  });
});
