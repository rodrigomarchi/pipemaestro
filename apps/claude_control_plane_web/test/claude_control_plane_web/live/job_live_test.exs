defmodule ClaudeControlPlaneWeb.JobLiveTest do
  use ClaudeControlPlaneWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias ClaudeControlPlane.Jobs

  setup :register_and_log_in_member

  setup %{workspace: workspace, user: user} do
    {runner, _token} = runner_fixture(workspace, user, %{name: "build-01"})
    %{runner: runner, job: job_fixture(runner, user, %{"prompt" => "crie um hello.txt"})}
  end

  defp event(seq, type, data), do: %{"seq" => seq, "type" => type, "data" => data}

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
    assert has_element?(view, "[data-testid=job-event][data-type=tool_use]", "Write")

    assert has_element?(
             view,
             "[data-testid=job-event][data-type=tool_result]",
             "Erro da ferramenta"
           )

    assert has_element?(view, "[data-testid=job-event][data-type=assistant_text]", "feito")

    refute has_element?(view, "[data-testid=job-typing]")
    Jobs.relay_delta(runner, job.id, "Estou olhando o **login**")
    assert has_element?(view, "[data-testid=job-typing]", "Estou olhando o")

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
  end

  test "cancels a queued job", %{conn: conn, workspace: workspace, runner: runner, job: job} do
    Jobs.subscribe({:runner, runner.id})
    {:ok, view, _html} = live(conn, ~p"/w/#{workspace.slug}/jobs/#{job.id}")

    view |> element("[data-testid=job-cancel]") |> render_click()

    assert_receive {:job_cancel, _id}
    assert has_element?(view, "[data-testid=job-status]", "Cancelado")
    refute has_element?(view, "[data-testid=job-cancel]")
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
    {:ok, _membership} = ClaudeControlPlane.Workspaces.add_member(other, user)

    assert_raise Ecto.NoResultsError, fn ->
      live(conn, ~p"/w/#{other.slug}/jobs/#{job.id}")
    end
  end
end
