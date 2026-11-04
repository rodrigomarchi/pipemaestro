defmodule PipeMaestroWeb.TaskLiveTest do
  use PipeMaestroWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias PipeMaestro.{Jobs, Tasks}
  alias PipeMaestroWeb.RunnerStatus

  setup :register_and_log_in_member

  setup %{workspace: workspace, user: user} do
    {runner, _token} = runner_fixture(workspace, user, %{name: "mac"})

    runner =
      with_directories(runner, [
        %{"name" => "app", "git" => true},
        %{"name" => "notas", "git" => false}
      ])

    %{runner: runner, pipeline: pipeline_fixture(workspace, %{"name" => "Duas etapas"})}
  end

  defp bring_online(runner) do
    test_pid = self()

    spawn_link(fn ->
      {:ok, _ref} = RunnerStatus.track(self(), runner)
      send(test_pid, :tracked)
      Process.sleep(:infinity)
    end)

    assert_receive :tracked
  end

  defp create_task(ctx) do
    {:ok, task} =
      Tasks.create_task(ctx.user, ctx.workspace, %{
        "title" => "Corrigir login",
        "prompt" => "O botão não responde",
        "pipeline_id" => ctx.pipeline.id,
        "runner_id" => ctx.runner.id,
        "directory" => "app"
      })

    task
  end

  # Plays the runner for the task's current job.
  defp finish_current(ctx, task, output, extra \\ %{}) do
    task = Tasks.get_task!(ctx.workspace, task.id)
    job = List.last(task.stage_runs).job
    # A test may have started it already.
    _started = Jobs.mark_started(ctx.runner, job.id)

    {:ok, _} =
      Jobs.append_event(ctx.runner, job.id, %{
        "seq" => 1,
        "type" => "assistant_text",
        "data" => %{"text" => "trabalhando em #{job.id}"}
      })

    {:ok, _} =
      Jobs.finish_job(
        ctx.runner,
        job.id,
        %{
          "status" => "succeeded",
          "exit_code" => 0,
          "structured_output" => output,
          "artifact" => "# Artefato de #{List.last(task.stage_runs).key}",
          "workdir" => "/w/worktrees/#{task.id}"
        }
        |> Map.merge(extra)
      )
  end

  describe "index" do
    test "the runner choice shows how busy each runner is, live", ctx do
      bring_online(ctx.runner)
      {:ok, view, _html} = live(ctx.conn, ~p"/w/#{ctx.workspace.slug}/tasks")
      view |> element("[data-testid=new-task]") |> render_click()

      runners = view |> element("[data-testid=task-runner]") |> render()
      assert runners =~ "mac (livre, capacidade 4)"

      job = job_fixture(ctx.runner, ctx.user)
      {:ok, _} = Jobs.mark_started(ctx.runner, job.id)
      _waiting = job_fixture(ctx.runner, ctx.user)

      runners = view |> element("[data-testid=task-runner]") |> render()
      assert runners =~ "mac (1/4 em execução, 1 na fila)"
    end

    test "starts a task with an online runner's directory", ctx do
      bring_online(ctx.runner)
      {:ok, view, _html} = live(ctx.conn, ~p"/w/#{ctx.workspace.slug}/tasks")
      assert has_element?(view, "[data-testid=no-tasks]")

      view |> element("[data-testid=new-task]") |> render_click()
      refute has_element?(view, "[data-testid=no-online-runners]")
      refute view |> element("[data-testid=task-directory]") |> render() =~ "app"

      view
      |> form("#new-task-form", task: %{runner_id: ctx.runner.id})
      |> render_change()

      assert has_element?(view, "[data-testid=task-issue-url]")
      directories = view |> element("[data-testid=task-directory]") |> render()
      assert directories =~ "app"
      assert directories =~ "notas (sem git: roda na pasta)"

      {:error, {:live_redirect, %{to: path}}} =
        view
        |> form("#new-task-form",
          task: %{
            title: "Corrigir login",
            prompt: "O botão não responde",
            pipeline_id: ctx.pipeline.id,
            runner_id: ctx.runner.id,
            directory: "app"
          }
        )
        |> render_submit()

      [task] = Tasks.list_tasks(ctx.workspace)
      assert path == "/w/#{ctx.workspace.slug}/tasks/#{task.id}"
    end

    test "explains when the chosen runner offers no directories", ctx do
      {bare, _token} = runner_fixture(ctx.workspace, ctx.user, %{name: "sem-raiz"})
      bring_online(bare)
      bring_online(ctx.runner)

      {:ok, view, _html} = live(ctx.conn, ~p"/w/#{ctx.workspace.slug}/tasks")
      view |> element("[data-testid=new-task]") |> render_click()

      view |> form("#new-task-form", task: %{runner_id: bare.id}) |> render_change()
      assert has_element?(view, "[data-testid=runner-without-directories]", "ROOT=~/src")

      view |> form("#new-task-form", task: %{runner_id: ctx.runner.id}) |> render_change()
      refute has_element?(view, "[data-testid=runner-without-directories]")
    end

    test "shows form errors and the missing prerequisites", ctx do
      {:ok, view, _html} = live(ctx.conn, ~p"/w/#{ctx.workspace.slug}/tasks")
      view |> element("[data-testid=new-task]") |> render_click()
      assert has_element?(view, "[data-testid=no-online-runners]")

      html = view |> form("#new-task-form", task: %{title: ""}) |> render_submit()
      assert html =~ "dê um título à tarefa"

      render_click(view, "close_new")
      refute has_element?(view, "#new-task-form")
    end

    test "lists tasks with their progress, live", ctx do
      task = create_task(ctx)
      {:ok, view, _html} = live(ctx.conn, ~p"/w/#{ctx.workspace.slug}/tasks")

      assert has_element?(view, "[data-testid=task-link-#{task.id}]", "Corrigir login")
      assert has_element?(view, "[data-testid=task-progress-#{task.id}]", "1/2 · Etapa A")

      finish_current(ctx, task, %{"status" => "ok", "resumo" => "a feita"}, %{
        "usage" => %{
          "fresh_input" => 100,
          "cache_read" => 2_900,
          "cache_creation" => 0,
          "output" => 500
        }
      })

      assert has_element?(view, "[data-testid=task-progress-#{task.id}]", "2/2 · Etapa B")

      # Each attempt shows its tokens and leads to its audit.
      {:ok, show, _html} = live(ctx.conn, ~p"/w/#{ctx.workspace.slug}/tasks/#{task.id}")

      assert has_element?(
               show,
               "[data-testid=stage-run-tokens-a-1]",
               "3.5k tokens · 97% do cache"
             )

      assert has_element?(show, "[data-testid=stage-run-audit-a-1]")

      # The CLI's telemetry for a job of the task does not disturb this page.
      send(show.pid, {:job_telemetry, Ecto.UUID.generate()})
      assert has_element?(show, "[data-testid=stage-run-tokens-a-1]")

      finish_current(ctx, task, %{"status" => "ok", "resumo" => "b feita"})
      assert has_element?(view, "[data-testid=task-status-#{task.id}]", "Concluída")
    end
  end

  describe "deciding" do
    test "the agent's options become buttons, and every decision stays in the history", ctx do
      task = create_task(ctx)

      finish_current(ctx, task, %{
        "status" => "bloqueado",
        "resumo" => "Onde corrigir?",
        "opcoes" => ["No cliente", "No servidor"]
      })

      {:ok, view, _html} = live(ctx.conn, ~p"/w/#{ctx.workspace.slug}/tasks/#{task.id}")
      assert has_element?(view, "[data-testid=decision-option-1]", "No servidor")
      refute has_element?(view, "[data-testid=task-decisions]")

      view
      |> form("#decision-form", decision: %{instructions: "com teste"})
      |> render_submit(%{"action" => "retry", "choice" => "No servidor"})

      assert has_element?(view, "[data-testid=task-decisions]", "No servidor")
      assert has_element?(view, "[data-testid=task-decisions]", "com teste")
      assert has_element?(view, "[data-testid=task-decisions]", ctx.user.name)

      assert [%{choice: "No servidor", decided_by_user_id: user_id}] = Tasks.list_decisions(task)
      assert user_id == ctx.user.id
    end
  end

  describe "talking to the task" do
    test "sends an instruction and asks for a pause while it runs", ctx do
      task = create_task(ctx)
      {:ok, view, _html} = live(ctx.conn, ~p"/w/#{ctx.workspace.slug}/tasks/#{task.id}")

      view
      |> form("#instruct-form", instruct: %{text: "Use o Safari"})
      |> render_submit()

      assert has_element?(view, "[data-testid=task-pending-instructions]", "Use o Safari")

      view |> element("[data-testid=task-request-pause]") |> render_click()
      assert has_element?(view, "[data-testid=task-pause-requested]")
      refute has_element?(view, "[data-testid=task-request-pause]")

      finish_current(ctx, task, %{"status" => "ok", "resumo" => "a feita"})
      assert has_element?(view, "[data-testid=task-status]", "Aguardando decisão")
      # Kept for whatever the decision starts next.
      assert has_element?(view, "[data-testid=task-pending-instructions]", "Use o Safari")
    end

    test "redoes the task from an earlier stage", ctx do
      task = create_task(ctx)
      finish_current(ctx, task, %{"status" => "ok", "resumo" => "a feita"})
      finish_current(ctx, task, %{"status" => "ok", "resumo" => "b feita"})

      {:ok, view, _html} = live(ctx.conn, ~p"/w/#{ctx.workspace.slug}/tasks/#{task.id}")
      assert has_element?(view, "[data-testid=task-status]", "Concluída")
      refute has_element?(view, "#instruct-form")

      view |> element("[data-testid=stage-redo-a]") |> render_click()
      assert has_element?(view, "[data-testid=task-status]", "Executando")
      assert has_element?(view, "[data-testid=stage-run-status-a-2]", "Executando")
      refute has_element?(view, "[data-testid=stage-redo-a]")
    end
  end

  describe "again" do
    test "runs a finished task again, or opens the form to start a copy", ctx do
      bring_online(ctx.runner)
      task = create_task(ctx)
      {:ok, _} = Tasks.cancel_task(task)
      {:ok, view, _html} = live(ctx.conn, ~p"/w/#{ctx.workspace.slug}/tasks/#{task.id}")

      {:error, {:live_redirect, %{to: path}}} =
        view |> element("[data-testid=task-rerun]") |> render_click()

      "/w/" <> rest = path
      again = Tasks.get_task!(ctx.workspace, rest |> String.split("/") |> List.last())
      assert again.id != task.id
      assert again.title == task.title

      {:ok, view, _html} = live(ctx.conn, ~p"/w/#{ctx.workspace.slug}/tasks/#{task.id}")
      assert has_element?(view, "[data-testid=task-duplicate][href$='?duplicate=#{task.id}']")

      {:ok, view, _html} = live(ctx.conn, ~p"/w/#{ctx.workspace.slug}/tasks?duplicate=#{task.id}")
      assert has_element?(view, "[data-testid=task-title][value='Corrigir login']")

      assert has_element?(view, "[data-testid=task-directory] option[selected][value=app]")
    end

    test "the list searches titles and prompts", ctx do
      create_task(ctx)
      {:ok, view, _html} = live(ctx.conn, ~p"/w/#{ctx.workspace.slug}/tasks")
      assert has_element?(view, "[data-testid^=task-link-]", "Corrigir login")

      view |> form("#tasks-search", search: %{q: "nada disso"}) |> render_change()
      refute has_element?(view, "[data-testid^=task-link-]")

      view |> form("#tasks-search", search: %{q: "botão"}) |> render_change()
      assert has_element?(view, "[data-testid^=task-link-]", "Corrigir login")
    end
  end

  describe "show" do
    test "shows each gate and the feedback the next attempt got", ctx do
      task = create_task(ctx)

      finish_current(ctx, task, %{"status" => "ok", "resumo" => "a feita"}, %{
        "gates" => [
          %{
            "command" => "mix format --check",
            "expect" => "pass",
            "exit_code" => 0,
            "passed" => true,
            "output" => ""
          },
          %{
            "command" => "mix test",
            "expect" => "pass",
            "exit_code" => 1,
            "passed" => false,
            "output" => "1 failure"
          }
        ]
      })

      {:ok, view, _html} = live(ctx.conn, ~p"/w/#{ctx.workspace.slug}/tasks/#{task.id}")
      gates = view |> element("[data-testid=stage-run-gates-a-1]") |> render()
      assert gates =~ "mix format --check"
      assert gates =~ "1 failure"

      assert has_element?(
               view,
               "[data-testid=stage-run-gate-a-1-1][data-passed=false]",
               "mix test"
             )

      assert has_element?(view, "[data-testid=stage-run-gate-a-1-0][data-passed=true]")

      assert has_element?(view, "[data-testid=stage-run-feedback-a-2]", "1 failure")
    end

    test "shows what each stage changed and what the task changed so far", ctx do
      task = create_task(ctx)
      {:ok, view, _html} = live(ctx.conn, ~p"/w/#{ctx.workspace.slug}/tasks/#{task.id}")
      refute has_element?(view, "[data-testid=task-files]")

      finish_current(ctx, task, %{"status" => "ok", "resumo" => "a feita"}, %{
        "changes" => %{
          "files" => [
            %{"path" => "lib/login.ex", "added" => 3, "removed" => 1},
            %{"path" => "priv/logo.png", "added" => nil, "removed" => nil}
          ],
          "patch" => "diff --git a/lib/login.ex b/lib/login.ex\n@@ -1 +1,3 @@\n-velho\n+novo\n",
          "truncated" => true,
          "task_files" => [%{"path" => "lib/login.ex", "added" => 3, "removed" => 1}]
        }
      })

      changes = view |> element("[data-testid=stage-run-changes-a-1]") |> render()
      assert changes =~ "2 arquivos alterados"
      assert changes =~ "+3"
      assert changes =~ "−1"
      assert changes =~ "priv/logo.png"
      assert changes =~ "binário"
      assert changes =~ "o patch foi cortado"
      assert has_element?(view, "[data-testid=stage-run-patch-a-1] .diff-add", "+novo")
      assert has_element?(view, "[data-testid=stage-run-patch-a-1] .diff-del", "-velho")
      assert has_element?(view, "[data-testid=task-files]", "lib/login.ex")
    end

    test "removes the worktree of a task that ended", ctx do
      task = create_task(ctx)
      finish_current(ctx, task, %{"status" => "ok", "resumo" => "a feita"})
      {:ok, view, _html} = live(ctx.conn, ~p"/w/#{ctx.workspace.slug}/tasks/#{task.id}")

      refute has_element?(view, "[data-testid=task-remove-worktree]")
      view |> element("[data-testid=task-cancel]") |> render_click()
      :ok = Jobs.subscribe({:runner, ctx.runner.id})

      view |> element("[data-testid=task-remove-worktree]") |> render_click()
      assert_receive {:worktree_remove, %{"task_id" => task_id}}
      assert task_id == task.id
      assert has_element?(view, "[data-testid=task-worktree-state]", "Removendo")
      refute has_element?(view, "[data-testid=task-remove-worktree]")

      {:ok, _} = Tasks.worktree_removed(ctx.runner, task.id, "arquivo em uso")
      assert has_element?(view, "[data-testid=task-worktree-state]", "arquivo em uso")
      assert has_element?(view, "[data-testid=task-remove-worktree]")

      view |> element("[data-testid=task-remove-worktree]") |> render_click()
      {:ok, _} = Tasks.worktree_removed(ctx.runner, task.id, nil)
      assert has_element?(view, "[data-testid=task-worktree-state]", "Removido")
      refute has_element?(view, "[data-testid=task-remove-worktree]")
    end

    test "shows how the runner set up the worktree", ctx do
      task = create_task(ctx)

      finish_current(ctx, task, %{"status" => "ok", "resumo" => "a feita"}, %{
        "setup" => %{
          "copied" => ["deps", "_build"],
          "command" => "mix deps.get",
          "exit_code" => 0,
          "output" => "All dependencies are up to date",
          "duration_ms" => 2_400
        }
      })

      {:ok, view, _html} = live(ctx.conn, ~p"/w/#{ctx.workspace.slug}/tasks/#{task.id}")
      setup = view |> element("[data-testid=stage-run-setup-a-1]") |> render()
      assert setup =~ "Ambiente preparado em 2 s"
      assert setup =~ "deps, _build"
      assert setup =~ "mix deps.get"
      assert setup =~ "All dependencies are up to date"
      refute has_element?(view, "[data-testid=stage-run-setup-b-1]")
    end

    test "follows the stages live until the task succeeds", ctx do
      task = create_task(ctx)
      {:ok, view, _html} = live(ctx.conn, ~p"/w/#{ctx.workspace.slug}/tasks/#{task.id}")

      assert has_element?(view, "[data-testid=task-status]", "Executando")
      assert has_element?(view, "[data-testid=task-where]", "mac:app")
      assert has_element?(view, "[data-testid=task-branch]", "cp/corrigir-login-")
      assert has_element?(view, "[data-testid=stage-run-status-a-1]", "Executando")
      assert has_element?(view, "[data-testid=stage-state-a]", "Executando")
      assert has_element?(view, "[data-testid=stage-state-b]", "Aguardando")
      refute has_element?(view, "[data-testid=stage-b] [data-testid^=stage-run-]")

      finish_current(ctx, task, %{"status" => "ok", "resumo" => "a feita"})
      assert has_element?(view, "[data-testid=stage-state-a]", "Concluída")

      view |> element("[data-testid=stage-run-steps-toggle-a-1]") |> render_click()
      assert has_element?(view, "[data-testid=stage-run-steps-a-1]", "trabalhando")

      view |> element("[data-testid=stage-run-steps-filter-a-1-errors]") |> render_click()
      refute has_element?(view, "[data-testid=stage-run-steps-a-1]", "trabalhando")
      view |> element("[data-testid=stage-run-steps-filter-a-1-agent]") |> render_click()
      assert has_element?(view, "[data-testid=stage-run-steps-a-1]", "trabalhando")
      view |> element("[data-testid=stage-run-steps-toggle-a-1]") |> render_click()
      refute has_element?(view, "[data-testid=stage-run-steps-a-1]")

      assert has_element?(view, "[data-testid=stage-run-summary-a-1]", "a feita")
      assert has_element?(view, "[data-testid=task-cost]", "US$")
      assert has_element?(view, "[data-testid=stage-run-artifact-a-1] h1", "Artefato de a")
      assert has_element?(view, "[data-testid=stage-run-artifact-a-1][phx-hook=Highlight]")
      refute has_element?(view, "[data-testid=stage-run-artifact-raw-a-1]")
      view |> element("[data-testid=stage-run-artifact-toggle-a-1]") |> render_click()
      assert has_element?(view, "[data-testid=stage-run-artifact-raw-a-1]", "# Artefato de a")
      refute has_element?(view, "[data-testid=stage-run-artifact-a-1]")
      view |> element("[data-testid=stage-run-artifact-toggle-a-1]") |> render_click()
      assert has_element?(view, "[data-testid=stage-run-artifact-a-1] h1", "Artefato de a")
      assert has_element?(view, "[data-testid=task-worktree]", "/w/worktrees/")
      assert has_element?(view, "[data-testid=stage-run-status-b-1]", "Executando")

      job_b = List.last(Tasks.get_task!(ctx.workspace, task.id).stage_runs).job

      {:ok, _} = Jobs.mark_started(ctx.runner, job_b.id)
      :ok = Jobs.relay_delta(ctx.runner, job_b.id, "Pensando em b")
      assert has_element?(view, "[data-testid=stage-b] [data-testid=job-typing]", "Pensando em b")

      {:ok, _} =
        Jobs.append_event(ctx.runner, job_b.id, %{
          "seq" => 9,
          "type" => "assistant_text",
          "data" => %{"text" => "evento ao vivo"}
        })

      assert has_element?(
               view,
               "[data-testid=stage-b] [data-testid=task-events]",
               "evento ao vivo"
             )

      refute has_element?(view, "[data-testid=job-typing]")

      finish_current(ctx, task, %{"status" => "ok", "resumo" => "b feita"})
      assert has_element?(view, "[data-testid=task-status]", "Concluída")
      refute has_element?(view, "[data-testid=task-cancel]")
    end

    test "the running stage's icons grow a strip; the finished steps filter it", ctx do
      task = create_task(ctx)
      job = List.last(Tasks.get_task!(ctx.workspace, task.id).stage_runs).job
      {:ok, _} = Jobs.mark_started(ctx.runner, job.id)
      {:ok, view, _html} = live(ctx.conn, ~p"/w/#{ctx.workspace.slug}/tasks/#{task.id}")

      live = "[data-testid=stage-a] [data-testid=task-events] [data-testid=job-event-strip-2]"

      {:ok, _} =
        Jobs.append_event(ctx.runner, job.id, %{
          "seq" => 2,
          "type" => "thinking",
          "data" => %{"text" => "Olhar o form", "duration_ms" => 1_500}
        })

      assert has_element?(view, "#{live} [data-testid=job-event-icon-2][data-type=thinking]")

      {:ok, _} =
        Jobs.append_event(ctx.runner, job.id, %{
          "seq" => 3,
          "type" => "tool_use",
          "data" => %{"name" => "Bash", "input" => %{"command" => "mix test"}}
        })

      assert has_element?(view, "#{live} [data-testid=job-event-icon-3][data-type=tool_use]")
      assert has_element?(view, "#{live} [data-testid=job-event-panel-3]", "$ mix test")

      finish_current(ctx, task, %{"status" => "ok", "resumo" => "a feita"})
      view |> element("[data-testid=stage-run-steps-toggle-a-1]") |> render_click()

      steps = "[data-testid=stage-run-steps-a-1]"
      assert has_element?(view, "#{steps} [data-testid=job-event-1]", "trabalhando")

      assert has_element?(
               view,
               "#{steps} [data-testid=job-event-strip-2] [data-testid=job-event-icon-3]"
             )

      view |> element("[data-testid=stage-run-steps-filter-a-1-thinking]") |> render_click()
      assert has_element?(view, "#{steps} [data-testid=job-event-icon-2][data-type=thinking]")
      assert has_element?(view, "#{steps} [data-testid=job-event-panel-2]", "Olhar o form")
      refute has_element?(view, "#{steps} [data-testid=job-event-icon-3]")
      refute has_element?(view, "#{steps} [data-testid=job-event-1]")

      view |> element("[data-testid=stage-run-steps-filter-a-1-tools]") |> render_click()
      assert has_element?(view, "#{steps} [data-testid=job-event-icon-3]")
      refute has_element?(view, "#{steps} [data-testid=job-event-icon-2]")
    end

    test "the running stage shows what it spent so far", ctx do
      task = create_task(ctx)
      job = List.last(Tasks.get_task!(ctx.workspace, task.id).stage_runs).job
      {:ok, _} = Jobs.mark_started(ctx.runner, job.id)
      {:ok, view, _html} = live(ctx.conn, ~p"/w/#{ctx.workspace.slug}/tasks/#{task.id}")

      assert has_element?(view, "[data-testid=stage-run-spent-a-1]", "até agora US$ 0")

      {:ok, _} =
        Jobs.record_telemetry(ctx.runner, job.id, [
          %{
            "name" => "api_request",
            "at" => "2026-11-03T12:00:00Z",
            "attrs" => %{"cost_usd" => 0.25, "output_tokens" => 2_000}
          }
        ])

      _ = render(view)
      send(view.pid, {:refresh_spent, job.id})
      assert has_element?(view, "[data-testid=stage-run-spent-a-1]", "US$ 0.2500 · 2.0k tokens")

      finish_current(ctx, task, %{"status" => "ok", "resumo" => "a feita"})
      refute has_element?(view, "[data-testid=stage-run-spent-a-1]")
    end

    test "a blocked stage takes a decision: retry with instructions, then advance", ctx do
      task = create_task(ctx)
      {:ok, view, _html} = live(ctx.conn, ~p"/w/#{ctx.workspace.slug}/tasks/#{task.id}")

      finish_current(ctx, task, %{"status" => "bloqueado", "resumo" => "Qual navegador?"})

      assert has_element?(view, "[data-testid=task-status]", "Aguardando decisão")
      assert has_element?(view, "[data-testid=decision-reason]", "Qual navegador?")

      view
      |> form("#decision-form", decision: %{instructions: "É no Safari"})
      |> render_submit(%{"action" => "retry"})

      assert has_element?(view, "[data-testid=stage-run-a-2]", "É no Safari")
      refute has_element?(view, "[data-testid=decision-panel]")

      finish_current(ctx, task, %{"status" => "bloqueado", "resumo" => "Ainda não"})

      view
      |> form("#decision-form", decision: %{instructions: ""})
      |> render_submit(%{"action" => "advance"})

      assert has_element?(view, "[data-testid=stage-run-status-b-1]", "Executando")
      assert render_click(view, "decide", %{"action" => "retry"}) =~ "não está aguardando"
    end

    test "cancels a task", ctx do
      task = create_task(ctx)
      {:ok, view, _html} = live(ctx.conn, ~p"/w/#{ctx.workspace.slug}/tasks/#{task.id}")

      view |> element("[data-testid=task-cancel]") |> render_click()
      assert has_element?(view, "[data-testid=task-status]", "Cancelada")
      assert render_click(view, "cancel") =~ "A tarefa já terminou"
    end
  end
end
