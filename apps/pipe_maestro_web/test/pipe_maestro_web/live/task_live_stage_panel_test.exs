defmodule PipeMaestroWeb.TaskLiveStagePanelTest do
  @moduledoc """
  The task's page in phases: the pipeline, vertical and light, and a stage's
  details in a wide panel, opened on demand and kept in the URL (`?etapa=`),
  live while the stage runs.
  """
  use PipeMaestroWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias PipeMaestro.{Jobs, Tasks}

  setup :register_and_log_in_member

  setup %{workspace: workspace, user: user} do
    {runner, _token} = runner_fixture(workspace, user, %{name: "mac"})
    runner = with_directories(runner, [%{"name" => "app", "git" => true}])

    %{runner: runner, pipeline: pipeline_fixture(workspace, %{"name" => "Duas etapas"})}
  end

  defp create_task(ctx, pipeline \\ nil) do
    {:ok, task} =
      Tasks.create_task(ctx.user, ctx.workspace, %{
        "title" => "Corrigir login",
        "prompt" => "O botão não responde",
        "pipeline_id" => (pipeline || ctx.pipeline).id,
        "project_id" => project_on(ctx.runner, "app").id
      })

    task
  end

  defp task_path(ctx, task, query \\ ""),
    do: "/w/#{ctx.workspace.slug}/tasks/#{task.id}" <> query

  # The running attempt of the stage `key`.
  defp running_job(ctx, task, key) do
    task = Tasks.get_task!(ctx.workspace, task.id)
    Enum.find(task.stage_runs, &(&1.key == key and &1.status == :running)).job
  end

  defp say(ctx, job, seq, text) do
    {:ok, event} =
      Jobs.append_event(ctx.runner, job.id, %{
        "seq" => seq,
        "type" => "assistant_text",
        "data" => %{"text" => text}
      })

    event
  end

  # Plays the runner for the running attempt of `key` (the last one, without a key).
  defp finish(ctx, task, key \\ nil, output, extra \\ %{}) do
    task = Tasks.get_task!(ctx.workspace, task.id)

    run =
      if key,
        do: Enum.find(task.stage_runs, &(&1.key == key and &1.status == :running)),
        else: List.last(task.stage_runs)

    _started = Jobs.mark_started(ctx.runner, run.job.id)
    say(ctx, run.job, 1, "trabalhando em #{run.key}")

    {:ok, _} =
      Jobs.finish_job(
        ctx.runner,
        run.job.id,
        Map.merge(
          %{
            "status" => "succeeded",
            "exit_code" => 0,
            "result" => "Resposta completa de #{run.key}",
            "structured_output" => output,
            "artifact" => "# Artefato de #{run.key}",
            "workdir" => "/w/worktrees/#{task.id}",
            "cost_usd" => 0.5,
            "duration_ms" => 61_000
          },
          extra
        )
      )
  end

  # A broadcast reaches the page, which hands it to the stage's panel with
  # `send_update/3`: one more message to itself. A render waits for that one too.
  defp settle(view), do: _ = render(view)

  defp etapa(path), do: URI.decode_query(URI.parse(path).query || "")["etapa"]

  describe "the overview" do
    test "the pipeline, vertical, with each stage's state and nothing of what it produced",
         ctx do
      task = create_task(ctx)

      finish(ctx, task, "a", %{"status" => "ok", "resumo" => "a feita"}, %{
        "num_turns" => 3,
        "usage" => %{"fresh_input" => 1_000, "cache_read" => 9_000, "output" => 500}
      })

      # Stage b runs, and has already said something.
      job_b = running_job(ctx, task, "b")
      {:ok, _} = Jobs.mark_started(ctx.runner, job_b.id)
      say(ctx, job_b, 1, "um passo de b")

      {:ok, view, html} = live(ctx.conn, task_path(ctx, task))

      assert has_element?(view, "[data-testid=task-overview] [data-testid=task-stage-a]")

      assert has_element?(
               view,
               "[data-testid=task-stage-a] [data-testid=task-stage-state-a]",
               "Concluída"
             )

      assert has_element?(
               view,
               "[data-testid=task-stage-b] [data-testid=task-stage-state-b]",
               "Executando"
             )

      assert has_element?(view, "[data-testid=task-stage-b][data-state=running]")
      # A finished stage tells how long it took and what it cost.
      assert has_element?(view, "[data-testid=task-stage-metrics-a]", "1 min 01 s")
      assert has_element?(view, "[data-testid=task-stage-metrics-a]", "US$ 0.5000")
      refute has_element?(view, "[data-testid=task-stage-metrics-b]")
      # What it said it did, what it used and when.
      assert has_element?(view, "[data-testid=task-stage-summary-a]", "a feita")

      assert has_element?(
               view,
               "[data-testid=task-stage-usage-a]",
               "10.5k tokens · 90% do cache · 3 turnos"
             )

      assert has_element?(view, "[data-testid=task-stage-when-a]", "terminou")
      assert has_element?(view, "[data-testid=task-stage-when-b]", "começou")
      refute has_element?(view, "[data-testid=task-stage-summary-b]")

      # Nothing a stage produced is rendered, nor its steps read.
      refute html =~ "Artefato de a"
      refute html =~ "Resposta completa de a"
      refute html =~ "um passo de b"
      refute has_element?(view, "[data-testid^=stage-run-artifact]")
      refute has_element?(view, "[data-testid^=stage-run-]")
      refute has_element?(view, "[data-testid=task-events]")
      refute has_element?(view, "[data-testid=task-stage-panel]")

      # The pipeline has the page: its entry, its end, nothing beside it.
      assert has_element?(view, "[data-testid=task-node-entrada]")
      assert has_element?(view, "[data-testid=task-overview-end]")
      refute has_element?(view, "[data-testid=task-sidebar]")
      # A running task takes no correction yet.
      refute has_element?(view, "[data-testid=task-node-corrigir]")

      # The message, pause and interruption go in the panel of the stage it is on.
      refute has_element?(view, "#instruct-form")
      view |> element("[data-testid=task-stage-a]") |> render_click()
      refute has_element?(view, "[data-testid=task-controls]")
      view |> element("[data-testid=task-stage-b]") |> render_click()
      assert has_element?(view, "[data-testid=task-stage-panel] #instruct-form")
      assert has_element?(view, "[data-testid=task-stage-panel] [data-testid=task-interrupt]")
    end

    test "a stage with more than one attempt says how many", ctx do
      task = create_task(ctx)
      finish(ctx, task, %{"status" => "bloqueado", "resumo" => "Qual navegador?"})

      {:ok, _task} =
        Tasks.retry_stage(Tasks.get_task!(ctx.workspace, task.id), "Safari", by: ctx.user)

      {:ok, view, _html} = live(ctx.conn, task_path(ctx, task))

      assert has_element?(view, "[data-testid=task-stage-attempts-a]", "2 tentativas")
      refute has_element?(view, "[data-testid=task-stage-attempts-b]")
    end

    test "follows the task, live", ctx do
      task = create_task(ctx)
      {:ok, view, _html} = live(ctx.conn, task_path(ctx, task))

      assert has_element?(view, "[data-testid=task-stage-state-a]", "Executando")
      assert has_element?(view, "[data-testid=task-stage-state-b]", "Aguardando")

      finish(ctx, task, %{"status" => "ok", "resumo" => "a feita"})

      assert has_element?(view, "[data-testid=task-stage-state-a]", "Concluída")
      assert has_element?(view, "[data-testid=task-stage-state-b]", "Executando")
      refute render(view) =~ "Artefato de a"
    end
  end

  describe "a stage's panel" do
    test "opens from its node, in the URL, artifact first; closes by X, Escape, backdrop and back",
         ctx do
      task = create_task(ctx)
      finish(ctx, task, %{"status" => "ok", "resumo" => "a feita"})
      {:ok, view, _html} = live(ctx.conn, task_path(ctx, task))

      view |> element("[data-testid=task-stage-a]") |> render_click()
      assert etapa(assert_patch(view)) == "a"

      panel = "[data-testid=task-stage-panel]"
      assert has_element?(view, "#{panel} [data-testid=task-stage-panel-title]", "Etapa A")

      assert has_element?(
               view,
               "#{panel} [data-testid=stage-run-artifact-a-1] h1",
               "Artefato de a"
             )

      # The result first; how it was checked, its steps and context a tab away.
      refute has_element?(view, "#{panel} [data-testid=stage-run-a-1-panel-resultado].hidden")
      assert has_element?(view, "#{panel} [data-testid=stage-run-a-1-panel-contexto].hidden")
      assert has_element?(view, "#{panel} [data-testid=stage-run-a-1-tab-passos]")

      assert has_element?(
               view,
               "#{panel} [data-testid=stage-run-a-1-panel-resultado] [data-testid=stage-run-summary-a-1]"
             )

      assert has_element?(view, "#{panel} [data-testid=stage-run-audit-a-1]")

      # The artifact flips between rendered and text, in the panel.
      view |> element("[data-testid=stage-run-artifact-toggle-a-1]") |> render_click()
      assert has_element?(view, "[data-testid=stage-run-artifact-raw-a-1]", "# Artefato de a")

      view |> element("[data-testid=task-stage-panel-close]") |> render_click()
      assert etapa(assert_patch(view)) == nil
      refute has_element?(view, panel)

      view |> element("[data-testid=task-stage-a]") |> render_click()
      assert_patch(view)
      view |> element(panel) |> render_keydown(%{"key" => "Escape"})
      assert etapa(assert_patch(view)) == nil
      refute has_element?(view, panel)

      view |> element("[data-testid=task-stage-a]") |> render_click()
      assert_patch(view)
      view |> element("[data-testid=task-stage-panel-backdrop]") |> render_click()
      assert etapa(assert_patch(view)) == nil
      refute has_element?(view, panel)

      # The browser's back: the URL without the stage.
      view |> element("[data-testid=task-stage-a]") |> render_click()
      assert_patch(view)
      render_patch(view, task_path(ctx, task))
      refute has_element?(view, panel)
    end

    test "a link to the stage opens it; an unknown stage is ignored", ctx do
      task = create_task(ctx)
      finish(ctx, task, %{"status" => "ok", "resumo" => "a feita"})

      {:ok, view, _html} = live(ctx.conn, task_path(ctx, task, "?etapa=a"))
      assert has_element?(view, "[data-testid=task-stage-panel] [data-testid=stage-run-a-1]")

      {:ok, view, _html} = live(ctx.conn, task_path(ctx, task, "?etapa=nao-existe"))
      refute has_element?(view, "[data-testid=task-stage-panel]")
      assert has_element?(view, "[data-testid=task-stage-a]")
    end

    test "a stage that never ran says what it will do", ctx do
      task = create_task(ctx)
      {:ok, view, _html} = live(ctx.conn, task_path(ctx, task, "?etapa=b"))

      panel = "[data-testid=task-stage-panel]"
      assert has_element?(view, "#{panel} [data-testid=task-stage-panel-pending]")
      assert render(element(view, panel)) =~ "Faça B"
      refute has_element?(view, "#{panel} [data-testid^=stage-run-]")
    end

    test "with several attempts, the latest shows and a selector picks another", ctx do
      task = create_task(ctx)
      finish(ctx, task, %{"status" => "bloqueado", "resumo" => "Qual navegador?"})

      {:ok, _task} =
        Tasks.retry_stage(Tasks.get_task!(ctx.workspace, task.id), "É no Safari", by: ctx.user)

      finish(ctx, task, %{"status" => "ok", "resumo" => "a feita"})

      {:ok, view, _html} = live(ctx.conn, task_path(ctx, task, "?etapa=a"))

      assert has_element?(view, "[data-testid=task-stage-attempt-a-1]")
      assert has_element?(view, "[data-testid=task-stage-attempt-a-2]")
      assert has_element?(view, "[data-testid=stage-run-a-2]")
      refute has_element?(view, "[data-testid=stage-run-a-1]")

      view |> element("[data-testid=task-stage-attempt-a-1]") |> render_click()
      assert has_element?(view, "[data-testid=stage-run-a-1]")
      refute has_element?(view, "[data-testid=stage-run-a-2]")
    end

    test "redoes from the stage, by its panel", ctx do
      task = create_task(ctx)
      finish(ctx, task, %{"status" => "ok", "resumo" => "a feita"})
      finish(ctx, task, %{"status" => "ok", "resumo" => "b feita"})

      {:ok, view, _html} = live(ctx.conn, task_path(ctx, task, "?etapa=a"))

      view
      |> element("[data-testid=task-stage-panel] [data-testid=stage-redo-a]")
      |> render_click()

      assert has_element?(view, "[data-testid=stage-redo-modal]")
      view |> form("#redo-form", redo: %{instructions: "com testes"}) |> render_submit()

      assert has_element?(view, "[data-testid=task-status]", "Executando")
      assert has_element?(view, "[data-testid=task-stage-state-a]", "Executando")
    end
  end

  describe "a running stage's panel" do
    test "streams that job live: its steps, its typing and what it spent; other jobs' events do not show",
         ctx do
      task = create_task(ctx)
      job = running_job(ctx, task, "a")
      {:ok, _} = Jobs.mark_started(ctx.runner, job.id)
      say(ctx, job, 1, "antes de abrir")

      {:ok, view, _html} = live(ctx.conn, task_path(ctx, task))
      refute has_element?(view, "[data-testid=task-events]")

      view |> element("[data-testid=task-stage-a]") |> render_click()
      assert_patch(view)

      events = "[data-testid=task-stage-panel] [data-testid=task-events]"
      # The timeline starts from what the job already said.
      assert has_element?(view, events, "antes de abrir")

      say(ctx, job, 2, "evento ao vivo")
      settle(view)
      assert has_element?(view, events, "evento ao vivo")

      :ok = Jobs.relay_delta(ctx.runner, job.id, "Pensando em a")
      settle(view)

      assert has_element?(
               view,
               "[data-testid=task-stage-panel] [data-testid=job-typing]",
               "Pensando em a"
             )

      # Another job's events are dropped.
      other = job_fixture(ctx.runner, ctx.user)
      {:ok, _} = Jobs.mark_started(ctx.runner, other.id)
      send(view.pid, {:job_event, say(ctx, other, 1, "de outro job")})
      send(view.pid, {:job_delta, other.id, "digitando em outro"})
      settle(view)
      refute render(view) =~ "de outro job"
      refute render(view) =~ "digitando em outro"

      assert has_element?(view, "[data-testid=stage-run-spent-a-1]", "até agora US$ 0")

      {:ok, _} =
        Jobs.record_telemetry(ctx.runner, job.id, [
          %{
            "name" => "api_request",
            "at" => "2026-11-03T12:00:00Z",
            "attrs" => %{"cost_usd" => 0.25, "output_tokens" => 2_000}
          }
        ])

      settle(view)
      send(view.pid, {:refresh_spent, job.id})
      settle(view)
      assert has_element?(view, "[data-testid=stage-run-spent-a-1]", "US$ 0.2500 · 2.0k tokens")

      # It ends: the panel turns to the artifact, without a reload.
      finish(ctx, task, "a", %{"status" => "ok", "resumo" => "a feita"})

      assert has_element?(
               view,
               "[data-testid=task-stage-panel] [data-testid=stage-run-artifact-a-1] h1",
               "Artefato de a"
             )

      refute has_element?(view, events)
      refute has_element?(view, "[data-testid=stage-run-spent-a-1]")
    end

    test "closing the panel stops following the job", ctx do
      task = create_task(ctx)
      job = running_job(ctx, task, "a")
      {:ok, _} = Jobs.mark_started(ctx.runner, job.id)

      {:ok, view, _html} = live(ctx.conn, task_path(ctx, task, "?etapa=a"))
      assert has_element?(view, "[data-testid=task-events]")

      view |> element("[data-testid=task-stage-panel-close]") |> render_click()
      assert_patch(view)

      say(ctx, job, 5, "depois de fechar")
      settle(view)
      refute render(view) =~ "depois de fechar"
      refute has_element?(view, "[data-testid=task-events]")
    end
  end

  describe "stages in parallel" do
    setup ctx do
      pipeline =
        pipeline_fixture(ctx.workspace, %{
          "stages" => [
            %{"key" => "impl", "name" => "Implementar", "prompt" => "p"},
            %{"key" => "seg", "name" => "Segurança", "prompt" => "p", "group" => "auditorias"},
            %{"key" => "perf", "name" => "Desempenho", "prompt" => "p", "group" => "auditorias"},
            %{"key" => "fim", "name" => "Consolidar", "prompt" => "p"}
          ]
        })

      %{parallel: pipeline}
    end

    test "the group's nodes say so, and each running stage opens its own live", ctx do
      task = create_task(ctx, ctx.parallel)
      finish(ctx, task, "impl", %{"status" => "ok", "resumo" => "feito"})

      seg = running_job(ctx, task, "seg")
      perf = running_job(ctx, task, "perf")
      {:ok, _} = Jobs.mark_started(ctx.runner, seg.id)
      {:ok, _} = Jobs.mark_started(ctx.runner, perf.id)

      {:ok, view, _html} = live(ctx.conn, task_path(ctx, task))

      assert has_element?(view, "[data-testid=task-stage-group-seg]", "em paralelo · auditorias")
      assert has_element?(view, "[data-testid=task-stage-group-perf]", "em paralelo · auditorias")
      assert has_element?(view, "[data-testid=task-stage-seg][data-state=running]")
      assert has_element?(view, "[data-testid=task-stage-perf][data-state=running]")

      events = "[data-testid=task-stage-panel] [data-testid=task-events]"

      view |> element("[data-testid=task-stage-seg]") |> render_click()
      assert etapa(assert_patch(view)) == "seg"
      say(ctx, seg, 1, "seg ao vivo")
      say(ctx, perf, 1, "perf ao vivo")
      settle(view)
      assert has_element?(view, events, "seg ao vivo")
      refute has_element?(view, events, "perf ao vivo")

      view |> element("[data-testid=task-stage-perf]") |> render_click()
      assert etapa(assert_patch(view)) == "perf"
      # Its timeline starts from what perf said, and follows perf only.
      assert has_element?(view, events, "perf ao vivo")
      refute has_element?(view, events, "seg ao vivo")
      say(ctx, seg, 2, "seg depois")
      say(ctx, perf, 2, "perf depois")
      settle(view)
      assert has_element?(view, events, "perf depois")
      refute has_element?(view, events, "seg depois")
    end
  end

  describe "a pending decision" do
    test "a banner over the pipeline opens the waiting stage, where the decision is taken",
         ctx do
      task = create_task(ctx)

      finish(ctx, task, %{
        "status" => "bloqueado",
        "resumo" => "Onde corrigir?",
        "opcoes" => ["No cliente", "No servidor"]
      })

      {:ok, view, _html} = live(ctx.conn, task_path(ctx, task))

      assert has_element?(view, "[data-testid=task-decision-banner]", "Onde corrigir?")
      assert has_element?(view, "[data-testid=task-stage-a][data-state=awaiting]")
      refute has_element?(view, "[data-testid=decision-panel]")

      view |> element("[data-testid=task-decision-open]") |> render_click()
      assert etapa(assert_patch(view)) == "a"

      panel = "[data-testid=task-stage-panel]"
      assert has_element?(view, "#{panel} [data-testid=decision-panel]")
      assert has_element?(view, "#{panel} [data-testid=decision-reason]", "Onde corrigir?")
      assert has_element?(view, "#{panel} [data-testid=decision-option-1]", "No servidor")
      assert has_element?(view, "#{panel} [data-testid=decision-suggest]")

      view
      |> form("#decision-form", decision: %{instructions: "com teste"})
      |> render_submit(%{"action" => "retry", "choice" => "No servidor"})

      refute has_element?(view, "[data-testid=task-decision-banner]")
      refute has_element?(view, "[data-testid=decision-panel]")
      # The panel stays on the stage, now on its new attempt.
      assert has_element?(view, "#{panel} [data-testid=stage-run-a-2]", "com teste")
      assert has_element?(view, "[data-testid=task-decision-0]", "No servidor")
    end
  end
end
