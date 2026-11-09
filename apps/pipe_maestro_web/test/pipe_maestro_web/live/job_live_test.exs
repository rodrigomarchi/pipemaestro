defmodule PipeMaestroWeb.JobLiveTest do
  use PipeMaestroWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias PipeMaestro.Jobs

  setup :register_and_log_in_member

  setup %{workspace: workspace, user: user} do
    {runner, _token} = runner_fixture(workspace, user, %{name: "build-01"})
    %{runner: runner, job: job_fixture(runner, user, %{"prompt" => "crie um hello.txt"})}
  end

  # Something inside a strip of the job's timeline.
  defp strip(seq), do: "[data-testid=job-events] [data-testid=job-event-strip-#{seq}] "

  defp event(seq, type, data), do: %{"seq" => seq, "type" => type, "data" => data}

  defp count(view, selector),
    do: view |> render() |> LazyHTML.from_document() |> LazyHTML.query(selector) |> Enum.count()

  test "icons join the strip read on mount; text closes it; a repeated event shows once", %{
    conn: conn,
    workspace: workspace,
    runner: runner,
    job: job
  } do
    {:ok, _} = Jobs.mark_started(runner, job.id)

    {:ok, _} =
      Jobs.append_event(runner, job.id, event(1, "assistant_text", %{"text" => "Vou ver"}))

    {:ok, _} = Jobs.append_event(runner, job.id, event(2, "thinking", %{"duration_ms" => 300}))

    {:ok, view, _html} = live(conn, ~p"/w/#{workspace.slug}/jobs/#{job.id}")
    assert has_element?(view, "[data-testid=job-events] [data-testid=job-event-1]", "Vou ver")
    assert has_element?(view, "#{strip(2)}[data-testid=job-event-icon-2]")

    {:ok, _} =
      Jobs.append_event(runner, job.id, event(3, "tool_use", %{"name" => "Bash", "text" => "ls"}))

    assert has_element?(view, "#{strip(2)}[data-testid=job-event-icon-3][data-type=tool_use]")
    assert has_element?(view, "#{strip(2)}[data-testid=job-event-panel-3]", "ls")
    assert count(view, "[data-testid^=job-event-strip-]") == 1

    # The window between subscribing and reading: the same event arrives twice.
    send(view.pid, {:job_event, job |> Jobs.list_events() |> List.last()})
    assert count(view, "[data-testid=job-event-icon-3]") == 1

    {:ok, _} = Jobs.append_event(runner, job.id, event(4, "assistant_text", %{"text" => "Achei"}))
    {:ok, _} = Jobs.append_event(runner, job.id, event(5, "tool_result", %{"text" => "ok"}))

    assert has_element?(view, "[data-testid=job-events] [data-testid=job-event-4]", "Achei")
    assert has_element?(view, "#{strip(5)}[data-testid=job-event-icon-5]")
    refute has_element?(view, "#{strip(2)}[data-testid=job-event-icon-5]")
    assert has_element?(view, "[data-testid=job-event-count]", "5 eventos")
  end

  test "shows the run growing live until it ends", %{
    conn: conn,
    workspace: workspace,
    runner: runner,
    job: job
  } do
    {:ok, view, _html} = live(conn, ~p"/w/#{workspace.slug}/jobs/#{job.id}")

    assert has_element?(view, "[data-testid=job-prompt-text]", "crie um hello.txt")
    assert has_element?(view, "[data-testid=job-status]", "Na fila")
    assert has_element?(view, "[data-testid=job-no-events]", "Aguardando")
    assert has_element?(view, "[data-testid=job-runner-name]", "build-01")

    {:ok, _} = Jobs.mark_started(runner, job.id)

    {:ok, _} =
      Jobs.append_event(runner, job.id, event(1, "system", %{"text" => "Sessão iniciada"}))

    {:ok, _} =
      Jobs.append_event(
        runner,
        job.id,
        event(2, "tool_use", %{"name" => "Write", "text" => "hello.txt"})
      )

    {:ok, _} =
      Jobs.append_event(
        runner,
        job.id,
        event(3, "tool_result", %{"text" => "ops", "is_error" => true})
      )

    {:ok, _} = Jobs.append_event(runner, job.id, event(4, "assistant_text", %{"text" => "feito"}))
    {:ok, _} = Jobs.append_event(runner, job.id, event(5, "result", %{"text" => "feito"}))

    assert has_element?(view, "[data-testid=job-status]", "Executando")
    assert has_element?(view, "[data-testid=job-event-count]", "5 eventos")

    assert has_element?(
             view,
             "#{strip(1)}[data-testid=job-event-icon-2][data-type=tool_use][data-state=normal]"
           )

    assert has_element?(view, "#{strip(1)}[data-testid=job-event-panel-2]", "Write")

    assert has_element?(
             view,
             "#{strip(1)}[data-testid=job-event-icon-3][data-type=tool_result][data-state=error]"
           )

    assert has_element?(view, "#{strip(1)}[data-testid=job-event-panel-3]", "Erro da ferramenta")

    assert has_element?(
             view,
             "[data-testid=job-events] [data-testid=job-event-4][data-type=assistant_text]",
             "feito"
           )

    assert has_element?(
             view,
             "[data-testid=job-events] [data-testid=job-event-5][data-type=result]"
           )

    refute has_element?(view, "[data-testid=job-typing]")
    Jobs.relay_delta(runner, job.id, "Estou olhando o **login**")
    assert has_element?(view, "[data-testid=job-typing]", "Estou olhando o")
    # The agent's place shows it too, without opening its drawer.
    assert has_element?(view, "[data-testid=job-node-typing]", "Estou olhando o")

    {:ok, _} =
      Jobs.append_event(runner, job.id, %{
        "seq" => 99,
        "type" => "assistant_text",
        "data" => %{"text" => "Estou olhando o login."}
      })

    refute has_element?(view, "[data-testid=job-typing]")

    {:ok, _} =
      Jobs.finish_job(runner, job.id, %{
        "status" => "succeeded",
        "result" => "**feito**, sem pendências",
        "exit_code" => 0,
        "num_turns" => 3,
        "duration_ms" => 850
      })

    assert has_element?(view, "[data-testid=job-status]", "Concluído")
    assert has_element?(view, "[data-testid=job-result] strong", "feito")
    assert has_element?(view, "[data-testid=job-duration]", "850 ms")
    refute has_element?(view, "[data-testid=job-cancel]")
  end

  test "audits how the agent worked: session, tokens, tools, API, environment", %{
    conn: conn,
    workspace: workspace,
    runner: runner,
    job: job
  } do
    {:ok, _} = Jobs.mark_started(runner, job.id)

    for {type, data, seq} <- [
          {"tool_use", %{"id" => "t1", "name" => "Bash", "text" => "mix test"}, 1},
          {"tool_result", %{"tool_use_id" => "t1", "is_error" => true, "text" => "falhou"}, 2},
          {"api_retry", %{"attempt" => 1, "text" => "Tentativa 1 de 10 da API: overloaded"}, 3}
        ] do
      {:ok, _} = Jobs.append_event(runner, job.id, event(seq, type, data))
    end

    {:ok, _} =
      Jobs.finish_job(runner, job.id, %{
        "status" => "succeeded",
        "session_id" => "sessao-123",
        "cli_version" => "2.1.317",
        "model" => "claude-haiku-5-5",
        "stop_reason" => "end_turn",
        "result_subtype" => "success",
        "duration_api_ms" => 4_000,
        "ttft_ms" => 700,
        "wall_ms" => 6_000,
        "usage" => %{
          "fresh_input" => 10,
          "cache_read" => 90,
          "cache_creation" => 0,
          "output" => 40
        },
        "model_usage" => %{
          "claude-haiku-5-5" => %{"fresh_input" => 10, "output" => 40, "cost_usd" => 0.002}
        },
        "permission_denials" => [
          %{"tool_name" => "Write", "input" => "{\"file_path\":\"/etc/x\"}"}
        ],
        "environment" => %{
          "tools" => ["Bash", "Read"],
          "mcp_servers" => [%{"name" => "grafana", "status" => "failed"}],
          "permission_mode" => "acceptEdits",
          "auth" => "none"
        },
        "stderr" => "aviso do CLI"
      })

    {:ok, view, _html} = live(conn, ~p"/w/#{workspace.slug}/jobs/#{job.id}")

    assert has_element?(view, "[data-testid=job-audit-session]", "sessao-123")
    assert has_element?(view, "[data-testid=job-audit-session]", "2.1.317")
    assert has_element?(view, "[data-testid=job-audit-session]", "acceptEdits")
    assert has_element?(view, "[data-testid=job-audit-cache-hit]", "90%")
    assert has_element?(view, "[data-testid=job-audit-model-claude-haiku-5-5]", "0.0020")
    assert has_element?(view, "[data-testid=job-audit-tool-calls-Bash]", "1")
    assert has_element?(view, "[data-testid=job-audit-api]", "1 nova tentativa")
    assert has_element?(view, "[data-testid=job-audit-denials]", "Write")
    assert has_element?(view, "[data-testid=job-audit-mcp-grafana]", "failed")
    assert has_element?(view, "[data-testid=job-audit-stderr]", "aviso do CLI")

    # The CLI's telemetry may arrive after the end: the audit follows it.
    {:ok, _} =
      Jobs.record_telemetry(runner, job.id, [
        %{
          "name" => "api_request",
          "at" => "2026-11-03T12:00:00Z",
          "attrs" => %{"duration_ms" => 1_234, "ttft_ms" => 500}
        },
        %{
          "name" => "tool_result",
          "at" => "2026-11-03T12:00:01Z",
          "attrs" => %{"tool_use_id" => "t1", "duration_ms" => 2_500}
        }
      ])

    assert render(view) =~ "1 s"
    assert has_element?(view, "[data-testid=job-audit-api]", "1 requisição")
    assert has_element?(view, "[data-testid=job-audit-tool-time-Bash]", "2 s")

    # Where the time went.
    assert has_element?(view, "[data-testid=job-audit-timing-api]", "4 s")
    assert has_element?(view, "[data-testid=job-audit-timing-tools]", "2 s")
    assert has_element?(view, "[data-testid=job-audit-timing-wall]", "6 s")
    refute has_element?(view, "[data-testid=job-audit-timing-gates]")
  end

  test "the audit names the session a stage resumed, and says when it was not there", %{
    conn: conn,
    workspace: workspace,
    runner: runner,
    job: job
  } do
    job
    |> Ecto.Changeset.change(
      context: Map.put(job.context || %{}, "resume_session_id", "sessao-a")
    )
    |> PipeMaestro.Repo.update!()

    {:ok, _} = Jobs.mark_started(runner, job.id)

    {:ok, _} =
      Jobs.finish_job(runner, job.id, %{
        "status" => "succeeded",
        "session_id" => "sessao-b",
        "session_resumed" => false
      })

    {:ok, view, _html} = live(conn, ~p"/w/#{workspace.slug}/jobs/#{job.id}")

    assert has_element?(view, "[data-testid=job-audit-session]", "Retomou a sessão")

    assert has_element?(
             view,
             "[data-testid=job-audit-session]",
             "sessao-a (indisponível: começou do zero)"
           )
  end

  test "what else the run reported: MCP, permission decisions, subagents, API origins", %{
    conn: conn,
    workspace: workspace,
    runner: runner,
    job: job
  } do
    {:ok, _} = Jobs.mark_started(runner, job.id)

    {:ok, _} =
      Jobs.record_telemetry(runner, job.id, [
        tel("mcp_server_connection", %{
          "status" => "failed",
          "transport_type" => "stdio",
          "server_scope" => "project"
        }),
        tel("tool_decision", %{"decision" => "reject", "source" => "hook"}),
        tel("subagent_completed", %{"agent_type" => "Explore"}),
        tel("api_request", %{"query_source" => "compact", "cost_usd" => 0.1}),
        tel("api_refusal", %{"error" => "refused"}),
        tel("metric:active_time", %{"value" => 90})
      ])

    {:ok, _} =
      Jobs.finish_job(runner, job.id, %{
        "status" => "succeeded",
        "gates" => [%{"duration_ms" => 3_000}]
      })

    {:ok, view, _html} = live(conn, ~p"/w/#{workspace.slug}/jobs/#{job.id}")

    assert has_element?(view, "[data-testid=job-audit-mcp-connections]", "1 falha")
    assert has_element?(view, "[data-testid=job-audit-decision-hook-reject]", "Recusadas")
    assert has_element?(view, "[data-testid=job-audit-subagents]", "Explore")
    assert has_element?(view, "[data-testid=job-audit-api-source-compact]")
    assert has_element?(view, "[data-testid=job-audit-api-refusals]", "1 recusa")
    assert has_element?(view, "[data-testid=job-audit-active-time]", "1 min 30 s")
    assert has_element?(view, "[data-testid=job-audit-timing-gates]", "3 s")
  end

  test "while it runs, shows what it spent so far", %{
    conn: conn,
    workspace: workspace,
    runner: runner,
    job: job
  } do
    {:ok, _} = Jobs.mark_started(runner, job.id)
    {:ok, view, _html} = live(conn, ~p"/w/#{workspace.slug}/jobs/#{job.id}")

    assert has_element?(view, "[data-testid=job-live-cost]", "US$ 0")
    refute has_element?(view, "[data-testid=job-audit]")

    {:ok, _} =
      Jobs.record_telemetry(runner, job.id, [
        tel("api_request", %{"cost_usd" => 0.5, "input_tokens" => 1_000, "output_tokens" => 500})
      ])

    # Read again once per interval, not on every batch.
    _ = render(view)
    send(view.pid, :refresh_live)

    assert has_element?(view, "[data-testid=job-live-cost]", "US$ 0.5000")
    assert has_element?(view, "[data-testid=job-live-tokens]", "1.5k")
    assert has_element?(view, "[data-testid=job-live-requests]", "1")

    {:ok, _} = Jobs.finish_job(runner, job.id, %{"status" => "succeeded"})
    refute has_element?(view, "[data-testid=job-live]")
    assert has_element?(view, "[data-testid=job-audit]")
  end

  defp tel(name, attrs), do: %{"name" => name, "at" => "2026-11-03T12:00:00Z", "attrs" => attrs}

  test "cancels a queued job", %{conn: conn, workspace: workspace, runner: runner, job: job} do
    Jobs.subscribe({:runner, runner.id})
    {:ok, view, _html} = live(conn, ~p"/w/#{workspace.slug}/jobs/#{job.id}")

    view |> element("[data-testid=job-cancel]") |> render_click()

    assert_receive {:job_cancel, _id}
    assert has_element?(view, "[data-testid=job-status]", "Cancelado")
    refute has_element?(view, "[data-testid=job-cancel]")
  end

  test "as a pipeline: each place opens its drawer; an ended job shows its result as fields", %{
    conn: conn,
    workspace: workspace,
    runner: runner,
    job: job
  } do
    path = ~p"/w/#{workspace.slug}/jobs/#{job.id}"
    {:ok, view, _html} = live(conn, path)

    # The run as a pipeline, its drawers closed and kept in the page.
    assert has_element?(view, "[data-testid=job-overview] [data-testid=job-node-entrada]")
    assert has_element?(view, "[data-testid=job-node-agente]", "Na fila")
    assert has_element?(view, "[data-testid=job-node-resultado]", "Ainda não terminou")
    assert has_element?(view, "[data-testid=job-drawer-agente].hidden")
    # A run in progress has the room: the sidebar opens closed to its icons.
    assert has_element?(view, "[data-testid=app-sidebar][data-collapsed=true][data-focus=true]")

    view |> element("[data-testid=job-node-agente]") |> render_click()
    assert_patch(view, path <> "?no=agente")
    assert has_element?(view, "[data-testid=job-drawer-agente]:not(.hidden)")
    assert has_element?(view, "[data-testid=job-panel-linha-do-tempo]:not(.hidden)")
    # Until it ends, there is no audit: the timeline is the only tab.
    refute has_element?(view, "[data-testid=job-tab-auditoria]")
    view |> element("[data-testid=job-drawer-agente-close]") |> render_click()
    assert_patch(view, path)
    assert has_element?(view, "[data-testid=job-drawer-agente].hidden")
    assert has_element?(view, "[data-testid=job-no-result]", "ainda não terminou")

    {:ok, _} = Jobs.mark_started(runner, job.id)

    {:ok, _} =
      Jobs.finish_job(runner, job.id, %{
        "status" => "succeeded",
        "result" => ~s({"status":"ok","resumo":"Feito em `lib/a.ex`.","notas":["um","dois"]}),
        "exit_code" => 0
      })

    {:ok, view, _html} = live(conn, path)

    assert has_element?(view, "[data-testid=app-sidebar][data-collapsed=false][data-focus=false]")
    assert has_element?(view, "header [data-testid=job-status]", "Concluído")
    assert has_element?(view, "[data-testid=job-drawer-fim].hidden [data-testid=job-duration]")

    # An old link to a tab opens the place that holds it now.
    {:ok, view, _html} = live(conn, path <> "?aba=auditoria")
    assert has_element?(view, "[data-testid=job-drawer-agente]:not(.hidden)")
    assert has_element?(view, "[data-testid=job-panel-auditoria]:not(.hidden)")
    assert has_element?(view, "[data-testid=job-panel-linha-do-tempo].hidden")

    {:ok, view, _html} = live(conn, path <> "?no=resultado")
    assert has_element?(view, "[data-testid=job-drawer-resultado]:not(.hidden)")

    assert has_element?(view, "[data-testid=job-result][data-format=fields]")
    assert has_element?(view, "[data-testid=job-result] [data-testid=agent-output-status]", "ok")

    assert has_element?(
             view,
             "[data-testid=job-result] [data-testid=agent-output-field-resumo] code",
             "lib/a.ex"
           )

    assert has_element?(
             view,
             "[data-testid=job-result] [data-testid=agent-output-field-notas] li",
             "dois"
           )

    # The result's place gives its summary.
    assert has_element?(view, "[data-testid=job-node-resultado]", "Feito em `lib/a.ex`.")

    view |> element("[data-testid=job-node-entrada]") |> render_click()
    assert_patch(view, path <> "?no=entrada")
    assert has_element?(view, "[data-testid=job-drawer-entrada]:not(.hidden)")
    assert has_element?(view, "[data-testid=job-drawer-resultado].hidden")
  end

  test "a running job shows it is being canceled; a failure shows its error", %{
    conn: conn,
    workspace: workspace,
    runner: runner,
    job: job
  } do
    {:ok, _} = Jobs.mark_started(runner, job.id)
    {:ok, view, _html} = live(conn, ~p"/w/#{workspace.slug}/jobs/#{job.id}")

    view |> element("[data-testid=job-cancel]") |> render_click()
    assert has_element?(view, "[data-testid=job-status]", "Cancelando")

    {:ok, _} =
      Jobs.finish_job(runner, job.id, %{"status" => "failed", "error" => "claude saiu com 1"})

    assert has_element?(view, "[data-testid=job-status]", "Falhou")
    assert has_element?(view, "[data-testid=job-error]", "claude saiu com 1")

    assert render_click(view, "cancel") =~ "A execução já terminou"
  end

  test "another workspace's job is not found, even for a member of both", %{
    conn: conn,
    user: user,
    job: job
  } do
    other = workspace_fixture()
    {:ok, _membership} = PipeMaestro.Workspaces.add_member(other, user)

    assert_raise Ecto.NoResultsError, fn ->
      live(conn, ~p"/w/#{other.slug}/jobs/#{job.id}")
    end
  end
end
