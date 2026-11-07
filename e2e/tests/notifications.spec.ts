/**
 * @section Central de notificações
 * @flow A Every workspace page has the bell; its panel opens on "Em andamento", empty, and on an empty inbox
 * @flow B A running task lights the bell's dot and shows in "Em andamento" with its status and stage, on any page
 * @flow C A task that pauses raises the bell's count live, with the toast; the notification survives a reload, and a click opens the task and marks it read
 * @flow D A task that ends notifies too; "Marcar todas como lidas" clears the count, and "Ver todas" opens the page, filtered by unread through the URL
 * @flow E The panel takes the whole width on a narrow screen
 */
import { expect, test } from "@playwright/test";
import { bootstrapOperator, uniqueSuffix, userPassword } from "../helpers/env";
import { RunnerProcess } from "../helpers/runnerProcess";
import { waitForLiveView } from "../helpers/liveView";
import { shot } from "../helpers/screenshots";
import { AppPage } from "../pages/AppPage";
import { BackofficePage } from "../pages/BackofficePage";
import { NotificationsPage } from "../pages/NotificationsPage";
import { PipelinesPage } from "../pages/PipelinesPage";
import { ProjectsPage } from "../pages/ProjectsPage";
import { RunnersPage } from "../pages/RunnersPage";
import { TasksPage } from "../pages/TasksPage";

test.describe("Notification center", () => {
  // Real CLI processes: the first one may compile the runner app.
  test.setTimeout(240_000);

  let runner: RunnerProcess;

  test.afterEach(() => runner?.cleanup());

  test("follows what runs and keeps what happened, from any page", async ({ page, browser }) => {
    const suffix = uniqueSuffix();
    const workspace = { name: `Avisos ${suffix}`, slug: `avisos-${suffix}` };
    const user = { name: `Nina ${suffix}`, email: `nina-${suffix}@e2e.test` };
    const runnerName = `avisos-${suffix}`;

    const backoffice = new BackofficePage(page);
    await backoffice.signInExpectingSuccess(bootstrapOperator.email, bootstrapOperator.password);
    await backoffice.createWorkspace(workspace.name);
    await backoffice.createMember(user.name, user.email, userPassword);

    const context = await browser.newContext();
    const app = new AppPage(await context.newPage());
    await app.signIn(user.email, userPassword);
    await app.expectBoard(workspace.name);

    const center = new NotificationsPage(app.page);

    // Flow A: the bell, nothing running and nothing to read.
    await expect(center.bell).toBeVisible();
    await expect(center.unreadCount).toBeHidden();
    await expect(center.activityIndicator).toBeHidden();
    await center.open();
    await expect(center.emptyActive).toBeVisible();
    await shot(app.page, "panel-active-empty");
    await center.inboxTab.click();
    await expect(center.emptyInbox).toBeVisible();
    await shot(app.page, "panel-inbox-empty");
    await center.close();

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
    await projects.create({ name: "Notas", runner: runnerName, directory: "notas" });

    const pipelines = new PipelinesPage(app.page);
    await pipelines.open(workspace.slug);
    await pipelines.createDefaults();

    // Flow B: a slow task that will pause runs, and shows from another page.
    const tasks = new TasksPage(app.page);
    await tasks.open(workspace.slug);
    const pausedId = await tasks.create({
      title: "Tela branca",
      prompt: "A tela fica branca. [lento] [bloqueio]",
      pipeline: "Prompt único",
      project: "Notas",
    });

    await app.openBoard(workspace.slug);
    await expect(center.activityIndicator).toBeVisible();
    await center.open();
    await expect(center.activeItem(pausedId)).toContainText("Tela branca");
    await expect(center.activeItem(pausedId)).toContainText("Rodando");
    await expect(center.activeItem(pausedId)).toContainText("etapa 1 de 1");
    await expect(center.activeItem(pausedId)).toContainText(runnerName);
    await shot(app.page, "panel-active-running");
    await center.close();

    // Flow C: the pause raises the count where the member is, without a reload.
    await expect(center.unreadCount).toHaveText("1", { timeout: 60_000 });
    await expect(app.toasts).toContainText("Tela branca aguarda decisão");
    await shot(app.page, "bell-unread");

    await app.page.reload();
    await waitForLiveView(app.page);
    await expect(center.unreadCount).toHaveText("1");

    await center.openInbox();
    const paused = center.item(pausedId, "task-awaiting-decision");
    await expect(paused).toContainText("Tela branca aguarda decisão");
    await expect(paused).toHaveAttribute("data-unread", "true");
    await shot(app.page, "panel-inbox");

    await paused.click();
    await expect(tasks.status).toHaveText("Aguardando decisão");
    expect(new URL(app.page.url()).pathname).toBe(`/w/${workspace.slug}/tasks/${pausedId}`);
    await expect(center.unreadCount).toBeHidden();

    await app.page.reload();
    await waitForLiveView(app.page);
    await expect(center.unreadCount).toBeHidden();

    // Flow D: a task that ends notifies too, and everything is marked read at once.
    await tasks.open(workspace.slug);
    const doneId = await tasks.create({
      title: "Nota rápida",
      prompt: "Anote o que mudou.",
      pipeline: "Prompt único",
      project: "Notas",
    });

    await expect(tasks.status).toHaveText("Concluída", { timeout: 60_000 });
    await expect(center.unreadCount).toHaveText("1");

    await center.openInbox();
    await expect(center.item(doneId, "task-succeeded")).toHaveAttribute("data-unread", "true");
    await center.markAllRead.click();
    await expect(center.item(doneId, "task-succeeded")).toHaveAttribute("data-unread", "false");
    await expect(center.unreadCount).toBeHidden();

    await center.seeAll.click();
    await expect(center.list).toBeVisible();
    await expect(center.item(pausedId, "task-awaiting-decision")).toBeVisible();
    await expect(center.item(doneId, "task-succeeded")).toBeVisible();
    await shot(app.page, "notifications-page");

    await center.filterUnread.click();
    await expect(app.page).toHaveURL(/\?filtro=nao-lidas$/);
    await expect(center.emptyInbox).toBeVisible();
    await app.page.reload();
    await waitForLiveView(app.page);
    await expect(center.emptyInbox).toBeVisible();
    await shot(app.page, "notifications-page-unread-empty");
    await center.filterAll.click();
    await expect(center.item(doneId, "task-succeeded")).toBeVisible();

    // Flow E: a narrow screen, both tabs.
    const viewport = app.page.viewportSize();
    await app.page.setViewportSize({ width: 390, height: 844 });
    await center.open();
    await shot(app.page, "panel-active-narrow");
    await center.inboxTab.click();
    await expect(center.item(doneId, "task-succeeded")).toBeVisible();
    await shot(app.page, "panel-inbox-narrow");
    await center.close();
    if (viewport) await app.page.setViewportSize(viewport);
  });
});
